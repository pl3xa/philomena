/**
 * Temp share button
 *
 * Adds a temp-share tag to the image and opens the resulting s.plexa.dev URL.
 */

import { assertNotNull } from './utils/assert';
import { delegate, leftClick } from './utils/events';
import { fetchJson, handleError } from './utils/requests';

export function setupTempShare() {
  delegate(document, 'click', {
    '.js-temp-share': leftClick((event: MouseEvent, target: HTMLAnchorElement) => {
      event.preventDefault();
      const imageId = assertNotNull(target.dataset.imageId);

      // Open the tab synchronously inside the click handler so popup blockers
      // allow it, then navigate it once the URL arrives.
      const tab = window.open('about:blank', '_blank');

      fetchJson('POST', `/images/${imageId}/temp_share`, {})
        .then(handleError)
        .then(response => response.json())
        .then(({ url }: { url: string }) => {
          if (tab) tab.location.href = url;
        })
        .catch(() => {
          tab?.close();
        });
    }),
  });
}
