/* eslint camelcase: ["error", { "allow": ["derpibooru_id"] }] */
import { fetchJson } from './utils/requests';

interface Candidate {
  id: number;
  url: string;
  thumbnail: string | null;
  artists: string[];
  sources: string[];
  additions: string[];
  errors: string[];
  token: string;
}

interface Result {
  candidates?: Candidate[];
  candidate?: Candidate;
  error?: string;
}

function link(text: string, url: string): HTMLAnchorElement {
  const anchor = document.createElement('a');
  anchor.textContent = text;
  anchor.href = url;
  anchor.target = '_blank';
  anchor.rel = 'noopener noreferrer';
  return anchor;
}

export function setupDerpibooruTags(reload = () => window.location.reload()) {
  const box = document.querySelector<HTMLElement>('.js-derpibooru-tags');
  if (!box) return;
  const check = box.querySelector<HTMLButtonElement>('.js-derpibooru-check');
  const manual = box.querySelector<HTMLButtonElement>('.js-derpibooru-manual');
  const status = box.querySelector<HTMLElement>('.js-derpibooru-status');
  const results = box.querySelector<HTMLElement>('.js-derpibooru-results');
  if (!check || !manual || !status || !results) return;
  const endpoint = `/images/${box.dataset.imageId}/derpibooru_tags`;
  let busy = false;
  let candidates: Candidate[] = [];

  function setBusy(value: boolean) {
    busy = value;
    box!.setAttribute('aria-busy', String(value));
    check!.disabled = value;
    manual!.disabled = value;
    results!.querySelectorAll<HTMLButtonElement>('button').forEach(button => {
      button.disabled = value || button.dataset.unavailable === 'true';
    });
  }

  function render() {
    results!.replaceChildren();
    candidates.forEach(candidate => {
      const row = document.createElement('div');
      row.className = 'derpibooru-tags__result';
      if (candidate.thumbnail) {
        const preview = link('', candidate.url);
        const img = document.createElement('img');
        img.src = candidate.thumbnail;
        img.className = 'derpibooru-tags__thumbnail';
        img.alt = `Derpibooru image ${candidate.id}`;
        img.width = 150;
        img.height = 150;
        img.loading = 'lazy';
        img.referrerPolicy = 'no-referrer';
        preview.append(img);
        row.append(preview);
      }
      const details = document.createElement('div');
      details.className = 'derpibooru-tags__details';
      details.append(link(`Derpibooru #${candidate.id}`, candidate.url));
      if (candidate.artists.length) {
        const artists = document.createElement('p');
        artists.textContent = candidate.artists.join(', ');
        details.append(artists);
      }
      candidate.sources.forEach((url, index) => {
        details.append(document.createTextNode(' · '), link(`Source ${index + 1}`, url));
      });
      const tags = document.createElement('p');
      tags.textContent = candidate.additions.length
        ? `Tags to add (${candidate.additions.length}): ${candidate.additions.join(', ')}`
        : 'No new tags';
      details.append(tags);
      if (candidate.errors.length) {
        const error = document.createElement('p');
        error.textContent = `Cannot merge: ${candidate.errors.join('; ')}. Existing tags will be preserved.`;
        details.append(error);
      }
      const merge = document.createElement('button');
      merge.type = 'button';
      merge.className = 'button';
      merge.textContent = 'Merge in tags';
      merge.dataset.unavailable = String(!candidate.additions.length || Boolean(candidate.errors.length));
      merge.disabled = merge.dataset.unavailable === 'true';
      merge.addEventListener('click', () => mergeCandidate(candidate));
      row.append(details, merge);
      results!.append(row);
    });
  }

  async function request(method: 'POST' | 'PUT', body: Record<string, unknown>): Promise<Result> {
    const response = await fetchJson(method, endpoint, body);
    const data: Result = await response.json();
    if (!response.ok && !data.candidate) throw new Error(data.error || 'The request failed. Please try again.');
    return data;
  }

  async function lookup(body: Record<string, unknown>) {
    if (busy) return;
    setBusy(true);
    candidates = [];
    render();
    status!.textContent = 'Checking Derpibooru…';
    try {
      const data = await request('POST', body);
      candidates = data.candidates || [];
      render();
      status!.textContent = candidates.length
        ? 'Review the matches and tag additions before merging.'
        : 'No matches found. You can try a manual ID.';
    } catch (error) {
      status!.textContent = error instanceof Error ? error.message : 'Could not check Derpibooru. Please try again.';
    } finally {
      setBusy(false);
    }
  }

  async function mergeCandidate(candidate: Candidate) {
    if (busy) return;
    setBusy(true);
    status!.textContent = 'Merging tags…';
    try {
      const data = await request('PUT', { token: candidate.token });
      if (data.candidate) {
        candidates = candidates.map(item => (item.id === candidate.id ? data.candidate! : item));
        render();
        status!.textContent = data.error || 'Review the updated additions before merging.';
      } else {
        reload();
      }
    } catch (error) {
      status!.textContent = error instanceof Error ? error.message : 'Could not merge tags. Please try again.';
    } finally {
      setBusy(false);
    }
  }

  check.addEventListener('click', () => lookup({ mode: 'reverse' }));
  manual.addEventListener('click', () => {
    if (busy) return;
    const input = window.prompt('Enter the official Derpibooru image ID:');
    if (input === null) return;
    const id = input.trim();
    if (!/^[1-9][0-9]{0,9}$/.test(id)) {
      status.textContent = 'Enter a positive numeric Derpibooru image ID.';
      return;
    }
    lookup({ derpibooru_id: id });
  });
}
