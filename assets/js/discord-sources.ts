interface Tag {
  name: string;
  aliased_tag: string | null;
}

const maxSnowflake = '18446744073709551615';

function isSnowflake(id: string): boolean {
  return /^[1-9]\d{0,19}$/.test(id) && (id.length < maxSnowflake.length || id <= maxSnowflake);
}

function messageDate(id: string): string {
  // Exact decimal division by 2^22 preserves the snowflake's timestamp without
  // rounding its 64-bit ID or requiring BigInt (our browser target is ES2019).
  // https://discord.com/developers/docs/reference#snowflakes
  let milliseconds = 0;
  let remainder = 0;
  for (const digit of id) {
    remainder = remainder * 10 + Number(digit);
    milliseconds = milliseconds * 10 + Math.floor(remainder / 4194304);
    remainder %= 4194304;
  }
  return new Date(milliseconds + 1420070400000).toISOString().slice(0, 10).replace(/-/g, '.');
}

function parseMessage(href: string) {
  try {
    const url = new URL(href);
    if (
      !['https:', 'http:'].includes(url.protocol) ||
      !/^(?:(?:www|ptb|canary)\.)?discord(?:app)?\.com$/.test(url.hostname)
    ) {
      return null;
    }
    const match = /^\/channels\/(@me|\d+)\/(\d+)\/(\d+)\/?$/.exec(url.pathname);
    if (!match || (match[1] !== '@me' && !isSnowflake(match[1])) || !match.slice(2).every(isSnowflake)) return null;

    return { guild: match[1], channel: match[2], date: messageDate(match[3]) };
  } catch {
    return null;
  }
}

export function createDiscordSourceDecorator() {
  const tags = new Map<string, Promise<Tag | null>>();
  const decorated = new WeakSet<HTMLAnchorElement>();

  function fetchTag(slug: string): Promise<Tag | null> {
    const cached = tags.get(slug);
    if (cached) return cached;

    const request = fetch(`/api/v1/json/tags/${encodeURIComponent(slug)}`, {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    })
      .then(async response => {
        if (response.status === 404) return null;
        if (!response.ok) throw new Error('Tag lookup failed');
        const { tag } = await response.json();
        if (typeof tag?.name !== 'string' || (tag.aliased_tag !== null && typeof tag.aliased_tag !== 'string')) {
          throw new Error('Invalid tag response');
        }
        return tag as Tag;
      })
      .catch(() => {
        // Allow a later source refresh to retry transient failures.
        tags.delete(slug);
        return null;
      });
    tags.set(slug, request);
    return request;
  }

  async function resolveTag(namespace: 'guildid' | 'channelid', id: string): Promise<string> {
    const fallback = `${namespace}:${id}`;
    let slug = `${namespace}-colon-${id}`;
    const visited = new Set<string>();
    // Protect against malformed alias cycles and unexpectedly long chains.
    while (!visited.has(slug) && visited.size < 10) {
      visited.add(slug);
      const tag = await fetchTag(slug);
      if (!tag) return fallback;
      if (!tag.aliased_tag) return tag.name;
      slug = tag.aliased_tag;
    }
    return fallback;
  }

  return async function decorateDiscordSources(): Promise<void> {
    const links = document.querySelectorAll<HTMLAnchorElement>('#image-source .image_source__link > a[href]');
    await Promise.all(
      Array.from(links, async link => {
        if (decorated.has(link)) return;
        const message = parseMessage(link.href);
        if (!message) return;
        decorated.add(link);

        const label = link.querySelector('strong') ?? document.createElement('strong');
        label.title = 'Discord server / channel / message date (UTC)';
        const guildLabel = message.guild === '@me' ? 'Direct Messages' : `guildid:${message.guild}`;
        label.textContent = `${guildLabel} / channelid:${message.channel} / ${message.date}`;
        link.textContent = '';
        link.append(label);

        const [guild, channel] = await Promise.all([
          message.guild === '@me' ? guildLabel : resolveTag('guildid', message.guild),
          resolveTag('channelid', message.channel),
        ]);
        label.textContent = `${guild} / ${channel} / ${message.date}`;
      }),
    );
  };
}
