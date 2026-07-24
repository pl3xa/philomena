/**
 * Share buttons
 *
 * Temp share adds a temp-share tag to the image and opens the resulting
 * s.plexa.dev URL. Public share is a plain link to the permanent hash URL,
 * but offers to add the public-share tag first when it is missing.
 */

import { assertNotUndefined } from './utils/assert';
import { delegate, leftClick } from './utils/events';
import { fetchJson, handleError } from './utils/requests';

function shareViaPost(imageId: string, path: string): Promise<boolean> {
  // Open the tab synchronously inside the click handler so popup blockers
  // allow it, then navigate it once the URL arrives.
  const tab = window.open('about:blank', '_blank');

  return fetchJson('POST', `/images/${imageId}/${path}`, {})
    .then(handleError)
    .then(response => response.json())
    .then(({ url }: { url: string }) => {
      if (tab) tab.location.href = url;
      return true;
    })
    .catch(() => {
      tab?.close();
      return false;
    });
}

export function setupTempShare() {
  delegate(document, 'click', {
    '.js-temp-share': leftClick((event: MouseEvent, target: HTMLAnchorElement) => {
      event.preventDefault();
      shareViaPost(assertNotUndefined(target.dataset.imageId), 'temp_share');
    }),
    '.js-public-share': leftClick((event: MouseEvent, target: HTMLAnchorElement) => {
      // Absent for non-editors, "true" once tagged - native navigation then.
      if (target.dataset.hasTag !== 'false') return;

      event.preventDefault();

      if (!window.confirm('Do you want to add public-share first?')) return;

      shareViaPost(assertNotUndefined(target.dataset.imageId), 'public_share').then(ok => {
        if (ok) target.dataset.hasTag = 'true';
      });
    }),
  });
}
