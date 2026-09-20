/* eslint camelcase: ["error", { "allow": ["derpibooru_id"] }] */
import { setupDerpibooruTags } from '../derpibooru-tags';
import { waitFor } from '@testing-library/dom';

let request: ReturnType<typeof vi.fn>;
let reload: ReturnType<typeof vi.fn>;
const candidate = {
  id: 123,
  url: 'https://derpibooru.org/images/123',
  thumbnail: 'https://derpicdn.net/thumb.png',
  artists: ['artist:example'],
  sources: ['https://example.com/art'],
  additions: ['new tag', '<script>alert(1)</script>'],
  errors: [],
  token: 'signed-preview',
};
const button = (selector: string) => document.querySelector<HTMLButtonElement>(selector)!;
const status = () => document.querySelector('.js-derpibooru-status')!.textContent;

beforeEach(() => {
  document.body.innerHTML = `<div class="js-derpibooru-tags" data-image-id="42">
    <button class="js-derpibooru-check">Check</button><button class="js-derpibooru-manual">Manual</button>
    <p class="js-derpibooru-status"></p><div class="js-derpibooru-results"></div></div>`;
  request = vi.fn().mockResolvedValue(Response.json({ candidates: [candidate] }));
  reload = vi.fn();
  vi.stubGlobal('fetch', request);
  setupDerpibooruTags(reload);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  document.body.innerHTML = '';
});

it('renders multiple horizontal result rows with escaped tags, previews, links and independent merge buttons', async () => {
  request.mockResolvedValue(Response.json({ candidates: [candidate, { ...candidate, id: 456 }] }));
  button('.js-derpibooru-check').click();
  await waitFor(() => expect(document.querySelectorAll('.derpibooru-tags__result')).toHaveLength(2));
  expect(document.querySelector('script')).toBeNull();
  expect(document.body.textContent).toContain('<script>alert(1)</script>');
  expect(document.querySelector('img')!.getAttribute('src')).toBe(candidate.thumbnail);
  expect(request.mock.calls[0][0]).toBe('/images/42/derpibooru_tags');
  expect(JSON.parse(request.mock.calls[0][1].body).mode).toBe('reverse');
});

it('uses the browser prompt and rejects invalid input or cancellation without a request', async () => {
  const prompt = vi.spyOn(window, 'prompt').mockReturnValue(null);
  button('.js-derpibooru-manual').click();
  prompt.mockReturnValue('https://example.com/123');
  button('.js-derpibooru-manual').click();
  expect(request).not.toHaveBeenCalled();
  expect(status()).toContain('positive numeric');
  prompt.mockReturnValue(' 123 ');
  button('.js-derpibooru-manual').click();
  await waitFor(() => expect(request).toHaveBeenCalledTimes(1));
  expect(JSON.parse(request.mock.calls[0][1].body).derpibooru_id).toBe('123');
});

it('merges only the signed selection, prevents double clicks and reloads on success', async () => {
  button('.js-derpibooru-check').click();
  await waitFor(() => expect(status()).toContain('Review'));
  request.mockResolvedValue(Response.json({ result: 'merged' }));
  button('.derpibooru-tags__result button').click();
  button('.derpibooru-tags__result button').click();
  await waitFor(() => expect(reload).toHaveBeenCalledTimes(1));
  expect(request).toHaveBeenCalledTimes(2);
  expect(JSON.parse(request.mock.calls[1][1].body).token).toBe('signed-preview');
  expect(JSON.parse(request.mock.calls[1][1].body).tags).toBeUndefined();
});

it('refreshes a stale preview and requires another merge click', async () => {
  button('.js-derpibooru-check').click();
  await waitFor(() => expect(status()).toContain('Review'));
  request.mockResolvedValue(
    Response.json(
      { candidate: { ...candidate, additions: ['updated'], token: 'new-token' }, error: 'Review updated tags' },
      { status: 409 },
    ),
  );
  button('.derpibooru-tags__result button').click();
  await waitFor(() => expect(status()).toBe('Review updated tags'));
  expect(document.body.textContent).toContain('updated');
  expect(reload).not.toHaveBeenCalled();
  request.mockResolvedValue(Response.json({ result: 'merged' }));
  button('.derpibooru-tags__result button').click();
  await waitFor(() => expect(reload).toHaveBeenCalledTimes(1));
  expect(JSON.parse(request.mock.calls[2][1].body).token).toBe('new-token');
});

it('disables empty diffs and rating conflicts', async () => {
  request.mockResolvedValue(
    Response.json({
      candidates: [
        { ...candidate, additions: [] },
        { ...candidate, id: 456, errors: ['conflicting ratings'] },
      ],
    }),
  );
  button('.js-derpibooru-check').click();
  await waitFor(() => expect(status()).toContain('Review'));
  document
    .querySelectorAll<HTMLButtonElement>('.derpibooru-tags__result button')
    .forEach(merge => expect(merge.disabled).toBe(true));
  expect(document.body.textContent).toContain('No new tags');
  expect(document.body.textContent).toContain('conflicting ratings');
});

it('shows upstream errors and lets the user retry', async () => {
  request.mockResolvedValue(Response.json({ error: 'Derpibooru is rate limiting requests' }, { status: 429 }));
  button('.js-derpibooru-check').click();
  await waitFor(() => expect(status()).toContain('rate limiting'));
  expect(button('.js-derpibooru-check').disabled).toBe(false);
  expect(reload).not.toHaveBeenCalled();
});

it('shows no matches and supports a subsequent manual search', async () => {
  request.mockResolvedValue(Response.json({ candidates: [] }));
  button('.js-derpibooru-check').click();
  await waitFor(() => expect(status()).toContain('No matches'));
  expect(button('.js-derpibooru-manual').disabled).toBe(false);
});
