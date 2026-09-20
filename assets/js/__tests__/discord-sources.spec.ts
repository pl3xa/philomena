/* eslint camelcase: ["error", { "allow": ["aliased_tag"] }] */
import { createDiscordSourceDecorator } from '../discord-sources';
import { imageSourcesCreator } from '../sources';

const messageUrl = 'https://discord.com/channels/261616212012695553/376978325681471489/1550650573861294203';
let request: ReturnType<typeof vi.fn>;

function mount(urls = [messageUrl]) {
  document.body.innerHTML =
    '<div class="js-sourcesauce"><form id="source-form"></form><div id="image-source"></div></div>';
  const container = document.querySelector('#image-source')!;
  return urls.map(url => {
    const row = document.createElement('div');
    row.className = 'image_source__link';
    const link = document.createElement('a');
    link.href = url;
    const strong = document.createElement('strong');
    strong.textContent = url;
    link.append(strong);
    row.append(link);
    container.append(row);
    return link;
  });
}

function mockTags(tags: Record<string, { name: string; aliased_tag: string | null }>) {
  request.mockImplementation(async (url: string) => {
    const slug = decodeURIComponent(url.split('/').pop()!);
    return tags[slug] ? Response.json({ tag: tags[slug] }) : new Response(null, { status: 404 });
  });
}

beforeEach(() => {
  request = vi.fn().mockResolvedValue(new Response(null, { status: 404 }));
  vi.stubGlobal('fetch', request);
});

afterEach(() => {
  vi.unstubAllGlobals();
  document.body.innerHTML = '';
});

it('follows alias chains, displays canonical names, and preserves the source anchor and URL', async () => {
  mockTags({
    'guildid-colon-261616212012695553': { name: 'guildid:261616212012695553', aliased_tag: 'server-colon-beardie' },
    'server-colon-beardie': { name: 'server:beardie', aliased_tag: null },
    'channelid-colon-376978325681471489': { name: 'channelid:376978325681471489', aliased_tag: 'old+channel' },
    'old+channel': { name: 'old channel', aliased_tag: 'channel-colon-beardie-dash-nsfw-dash-general' },
    'channel-colon-beardie-dash-nsfw-dash-general': { name: 'channel:beardie-nsfw-general', aliased_tag: null },
  });
  const [link] = mount();
  const strong = link.querySelector('strong');
  const pending = createDiscordSourceDecorator()();
  expect(link.textContent).not.toContain('discord.com');
  await pending;

  expect(link.textContent).toBe('server:beardie / channel:beardie-nsfw-general / 2026.09.18');
  expect(link.getAttribute('href')).toBe(messageUrl);
  expect(link.querySelector('strong')).toBe(strong);
  expect(request).toHaveBeenCalledWith('/api/v1/json/tags/old%2Bchannel', expect.any(Object));
});

it('shares in-flight lookups across sources and refreshes without duplicating labels', async () => {
  const decorate = createDiscordSourceDecorator();
  const links = mount([messageUrl, messageUrl]);
  await decorate();
  await decorate();
  expect(request).toHaveBeenCalledTimes(2);
  links.forEach(link => expect(link.querySelectorAll('strong')).toHaveLength(1));

  const [replacement] = mount();
  await decorate();
  expect(replacement.textContent).toContain('2026.09.18');
  expect(request).toHaveBeenCalledTimes(2);
});

it('handles missing aliases and failed lookups independently, then retries failures on refresh', async () => {
  request.mockImplementation(async (url: string) => {
    if (url.includes('guildid')) throw new Error('Offline');
    return Response.json({ tag: { name: 'channel:known', aliased_tag: null } });
  });
  const decorate = createDiscordSourceDecorator();
  const [link] = mount();
  await decorate();
  expect(link.textContent).toBe('guildid:261616212012695553 / channel:known / 2026.09.18');
  mount();
  await decorate();
  expect(request).toHaveBeenCalledTimes(3);
});

it('bounds alias cycles and renders tag names as text', async () => {
  mockTags({
    'guildid-colon-261616212012695553': { name: 'guildid:261616212012695553', aliased_tag: 'loop' },
    loop: { name: 'loop', aliased_tag: 'guildid-colon-261616212012695553' },
    'channelid-colon-376978325681471489': { name: 'channel:<img src=x onerror=alert(1)>', aliased_tag: null },
  });
  const [link] = mount();
  await createDiscordSourceDecorator()();
  expect(link.textContent).toContain('guildid:261616212012695553 / channel:<img src=x onerror=alert(1)>');
  expect(link.querySelector('img')).toBeNull();
  expect(request).toHaveBeenCalledTimes(3);
});

it('leaves unrelated links, non-message Discord URLs, and invalid IDs alone', async () => {
  const urls = [
    messageUrl.replace('discord.com', 'discord.com.evil.example'),
    messageUrl.replace('discord.com', 'example.com'),
    messageUrl.replace('https:', 'ftp:'),
    messageUrl.replace('/261616212012695553/', '/@other/'),
    messageUrl.replace('1550650573861294203', '18446744073709551616'),
    'https://discord.com/channels/261616212012695553/376978325681471489',
    'https://discord.gg/invite',
  ];
  const links = mount(urls);
  await createDiscordSourceDecorator()();
  expect(links.map(link => link.textContent)).toEqual(urls);
  expect(request).not.toHaveBeenCalled();
});

it('supports legacy and alternate Discord hosts, query strings, and trailing slashes', async () => {
  const links = mount([
    messageUrl.replace('discord.com', 'discordapp.com'),
    `${messageUrl.replace('discord.com', 'canary.discord.com')}/?jump=1#message`,
    messageUrl.replace('discord.com', 'ptb.discord.com'),
  ]);
  await createDiscordSourceDecorator()();
  links.forEach(link => expect(link.textContent).toContain('2026.09.18'));
});

it('decodes a snowflake just before UTC midnight without rounding it into the next day', async () => {
  const midnight = BigInt(Date.parse('2026-09-19T00:00:00.000Z') - 1420070400000);
  const messageId = String((midnight << BigInt(22)) - BigInt(1));
  const [link] = mount([messageUrl.replace('1550650573861294203', messageId)]);
  await createDiscordSourceDecorator()();
  expect(link.textContent).toContain('2026.09.18');
});

it('does no work outside the image source block', async () => {
  const [link] = mount();
  document.body.append(link);
  await createDiscordSourceDecorator()();
  expect(link.textContent).toBe(messageUrl);
  expect(request).not.toHaveBeenCalled();
});

it('degrades gracefully on server errors and malformed responses', async () => {
  request.mockResolvedValueOnce(new Response(null, { status: 500 })).mockResolvedValueOnce(Response.json({ tag: {} }));
  const [link] = mount();
  await createDiscordSourceDecorator()();
  expect(link.textContent).toBe('guildid:261616212012695553 / channelid:376978325681471489 / 2026.09.18');
});

it('decorates on page initialization and after an AJAX source edit', async () => {
  const [link] = mount();
  const replacement = document.querySelector('.js-sourcesauce')!.outerHTML;
  imageSourcesCreator();
  await vi.waitFor(() => expect(link.textContent).toContain('2026.09.18'));
  document
    .querySelector('#source-form')!
    .dispatchEvent(new CustomEvent('fetchcomplete', { bubbles: true, detail: new Response(replacement) }));
  await vi.waitFor(() => {
    expect(link.isConnected).toBe(false);
    expect(document.querySelector('.image_source__link a')!.textContent).toContain('2026.09.18');
  });
});
