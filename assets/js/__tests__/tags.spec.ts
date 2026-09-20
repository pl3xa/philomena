import { initTagDropdown } from '../tags';
import { fire } from '../utils/events';

const booru = window.booru;
const actions = ['unwatch', 'watch', 'unspoiler', 'spoiler', 'unhide', 'hide', 'signin', 'filter'];
let prompt: ReturnType<typeof vi.fn>;
let alert: ReturnType<typeof vi.fn>;
let reload: ReturnType<typeof vi.fn>;
let request: ReturnType<typeof vi.fn>;
let link: HTMLAnchorElement;

function mount(withAlias = true) {
  document.body.innerHTML = `<span class="tag dropdown" data-tag-id="123">
    <a class="tag__name">source</a>
    ${actions.map(action => `<a class="tag__dropdown__link hidden" data-tag-action="${action}"></a>`).join('')}
    ${withAlias ? '<a class="tag__dropdown__link" href="/tags/source/alias/edit" data-tag-alias-url="/tags/source/alias">Alias</a>' : ''}
  </span>`;
  initTagDropdown();
  link = document.querySelector('[data-tag-alias-url]')!;
}

beforeEach(() => {
  prompt = vi.fn().mockReturnValue(' target ');
  alert = vi.fn();
  reload = vi.fn();
  request = vi.fn().mockResolvedValue(Response.json({ success: true }));
  vi.stubGlobal('fetch', request);
  vi.stubGlobal('window', {
    booru: {
      ...booru,
      userIsSignedIn: true,
      userCanEditFilter: true,
      watchedTagList: [],
      spoileredTagList: [],
      hiddenTagList: [],
    },
    prompt,
    alert,
    location: { reload },
  });
  mount();
});

afterEach(() => vi.unstubAllGlobals());

it('prompts and submits the hovered source and trimmed target with CSRF protection, then reloads', async () => {
  link.click();
  expect(prompt).toHaveBeenCalledWith('What do you want to alias this tag to');
  expect(request).toHaveBeenCalledWith(
    '/tags/source/alias',
    expect.objectContaining({
      method: 'PUT',
      credentials: 'same-origin',
      headers: expect.objectContaining({ 'x-csrf-token': booru.csrfToken, 'x-requested-with': 'xmlhttprequest' }),
      // eslint-disable-next-line camelcase
      body: JSON.stringify({ tag: { target_tag: 'target' }, _method: 'PUT' }),
    }),
  );
  await vi.waitFor(() => expect(reload).toHaveBeenCalledOnce());
  expect(alert).not.toHaveBeenCalled();
});

it('does nothing on Cancel', () => {
  prompt.mockReturnValue(null);
  link.click();
  expect(request).not.toHaveBeenCalled();
  expect(alert).not.toHaveBeenCalled();
  expect(reload).not.toHaveBeenCalled();
});

it('rejects blank input without a request', () => {
  prompt.mockReturnValue('  ');
  link.click();
  expect(request).not.toHaveBeenCalled();
  expect(alert).toHaveBeenCalledWith('Please enter a target tag name.');
});

it('alerts the server validation reason and allows retry', async () => {
  request.mockResolvedValue(
    Response.json({ success: false, error: 'Aliased tag is the same tag as the source' }, { status: 422 }),
  );
  link.click();
  await vi.waitFor(() =>
    expect(alert).toHaveBeenCalledWith('Failed to alias tag: Aliased tag is the same tag as the source'),
  );
  expect(reload).not.toHaveBeenCalled();
  expect(link).not.toHaveAttribute('aria-disabled');
  request.mockResolvedValue(Response.json({ success: true }));
  link.click();
  await vi.waitFor(() => expect(reload).toHaveBeenCalledOnce());
});

it.each([
  [403, 'You do not have permission'],
  [500, 'HTTP 500'],
  [200, 'Unexpected server response'],
])('handles non-JSON HTTP %s without reloading', async (status, reason) => {
  request.mockResolvedValue(new Response('<html>Error</html>', { status, headers: { 'content-type': 'text/html' } }));
  link.click();
  await vi.waitFor(() => expect(alert).toHaveBeenCalledWith(expect.stringContaining(reason)));
  expect(reload).not.toHaveBeenCalled();
});

it('handles expired-session redirects without treating the login page as success', async () => {
  const response = new Response('<html>Sign in</html>');
  Object.defineProperty(response, 'redirected', { value: true });
  request.mockResolvedValue(response);
  link.click();
  await vi.waitFor(() => expect(alert).toHaveBeenCalledWith(expect.stringContaining('session may have expired')));
  expect(reload).not.toHaveBeenCalled();
});

it('handles network failures', async () => {
  request.mockRejectedValue(new Error('Network unavailable'));
  link.click();
  await vi.waitFor(() => expect(alert).toHaveBeenCalledWith('Failed to alias tag: Network unavailable'));
  expect(reload).not.toHaveBeenCalled();
});

it('handles malformed JSON', async () => {
  request.mockResolvedValue(new Response('{', { headers: { 'content-type': 'application/json' } }));
  link.click();
  await vi.waitFor(() => expect(alert).toHaveBeenCalledOnce());
  expect(reload).not.toHaveBeenCalled();
});

it('ignores duplicate clicks while the request is pending', async () => {
  let resolve!: (response: Response) => void;
  request.mockReturnValue(
    new Promise<Response>(done => {
      resolve = done;
    }),
  );
  link.click();
  link.click();
  expect(prompt).toHaveBeenCalledOnce();
  expect(request).toHaveBeenCalledOnce();
  expect(link).toHaveAttribute('aria-disabled', 'true');
  resolve(Response.json({ success: true }));
  await vi.waitFor(() => expect(reload).toHaveBeenCalledOnce());
});

it.each([true, false])('preserves Watch and Filter actions with alias entry present: %s', withAlias => {
  mount(withAlias);
  const watch = document.querySelector<HTMLElement>('[data-tag-action="watch"]')!;
  const hide = document.querySelector<HTMLElement>('[data-tag-action="hide"]')!;
  fire(watch, 'fetchcomplete', new Response());
  fire(hide, 'fetchcomplete', new Response());
  expect(window.booru.watchedTagList).toEqual([123]);
  expect(window.booru.hiddenTagList).toEqual([123]);
  expect(document.querySelector('.tag')).toHaveClass('tag--watched', 'tag--hidden');
});
