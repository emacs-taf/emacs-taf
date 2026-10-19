// YouTube renderer data -> bounded, versioned plain client data.
export const text = value => typeof value === 'string' ? value : value?.simpleText ?? value?.content ?? value?.runs?.map(x => x.text || '').join('') ?? '';
export function all(root, key) {
  const result = [];
  const visit = node => {
    if (!node || typeof node !== 'object') return;
    for (const [name, value] of Object.entries(node)) {
      if (/^(adSlotRenderer|inFeedAdLayoutRenderer|promoted.*Renderer)$/.test(name)) continue;
      if (name === key) result.push(value);
      visit(value);
    }
  };
  visit(root);
  return result;
}
export const first = (root, key) => all(root, key)[0];
const thumb = value => {
  const images = value?.thumbnails || value?.sources || (Array.isArray(value) ? value : []);
  return images.filter(x => x.url).sort((a, b) => (b.width || 0) - (a.width || 0))[0]?.url || '';
};
const byline = value => ({ name: text(value), id: first(value, 'browseEndpoint')?.browseId || '' });
export const cursor = (endpoint, token, kind = 'items', video_id = '') => token ? Buffer.from(JSON.stringify({ v: 1, endpoint, token, kind, video_id })).toString('base64url') : null;
export function nextCursor(data, endpoint = 'browse', kind = 'items', videoId = '') {
  const continuation = all(data, 'continuationItemRenderer').at(-1)?.continuationEndpoint;
  const token = continuation?.continuationCommand?.token;
  const api = continuation?.commandMetadata?.webCommandMetadata?.apiUrl?.split('/v1/')[1] || endpoint;
  return cursor(api, token, kind, videoId);
}
export function items(data) {
  const result = [], seen = new Set();
  const add = item => {
    if (!item.id || !item.title || seen.has(`${item.kind}:${item.id}`)) return;
    seen.add(`${item.kind}:${item.id}`); result.push(item);
  };
  const visit = node => {
    if (!node || typeof node !== 'object') return;
    for (const [name, value] of Object.entries(node)) {
      if (/^(adSlotRenderer|inFeedAdLayoutRenderer|promoted.*Renderer|menuRenderer|topbar|header)$/.test(name)) continue;
      if (['videoRenderer', 'gridVideoRenderer', 'compactVideoRenderer', 'playlistVideoRenderer', 'playlistPanelVideoRenderer'].includes(name)) {
        const author = byline(value.ownerText || value.shortBylineText || value.longBylineText);
        add({ kind: 'video', id: value.videoId, title: text(value.title), thumbnail: thumb(value.thumbnail),
          author: author.name, channel_id: author.id, avatar: thumb(first(value, 'channelThumbnailWithLinkRenderer')?.thumbnail),
          duration: text(value.lengthText) || text(first(value, 'thumbnailOverlayTimeStatusRenderer')?.text),
          views: text(value.viewCountText), published: text(value.publishedTimeText),
          live: !!value.badges?.some(x => x.metadataBadgeRenderer?.style?.includes('LIVE')),
          playlist_item_id: value.setVideoId || null });
        continue;
      }
      if (name === 'lockupViewModel' && value.contentId) {
        const meta = value.metadata?.lockupMetadataViewModel;
        const parts = all(meta?.metadata, 'metadataParts').flat().map(x => text(x.text)).filter(Boolean);
        const kind = value.contentType?.includes('PLAYLIST') ? 'playlist' : value.contentType?.includes('VIDEO') ? 'video' : null;
        if (kind) add({ kind, id: value.contentId, title: text(meta?.title),
          thumbnail: thumb(first(value.contentImage, 'thumbnailViewModel')?.image),
          author: parts[0] || '', channel_id: first(meta?.image || meta?.metadata, 'browseEndpoint')?.browseId || '',
          avatar: thumb(first(meta?.image, 'avatarViewModel')?.image),
          duration: text(first(value.contentImage, 'thumbnailBadgeViewModel')?.text),
          views: parts[1] || '', published: parts[2] || '', live: false });
        continue;
      }
      if (name === 'shortsLockupViewModel' || name === 'reelItemRenderer') {
        const id = value.videoId || first(value, 'reelWatchEndpoint')?.videoId;
        add({ kind: 'short', id, title: text(value.overlayMetadata?.primaryText) || text(value.headline),
          thumbnail: thumb(value.thumbnail) || thumb(first(value.thumbnailViewModel, 'thumbnailViewModel')?.image),
          author: '', channel_id: '', duration: 'Shorts',
          views: text(value.overlayMetadata?.secondaryText) || text(value.viewCountText), published: '' });
        continue;
      }
      if (['channelRenderer', 'gridChannelRenderer'].includes(name)) {
        add({ kind: 'channel', id: value.channelId, title: text(value.title), thumbnail: thumb(value.thumbnail),
          author: text(value.subscriberCountText), description: text(value.descriptionSnippet),
          subscribed: first(value, 'subscribeButtonRenderer')?.subscribed ?? null });
        continue;
      }
      if (['playlistRenderer', 'gridPlaylistRenderer'].includes(name)) {
        add({ kind: 'playlist', id: value.playlistId, title: text(value.title),
          thumbnail: thumb(value.thumbnails?.[0] || value.thumbnailRenderer?.playlistVideoThumbnailRenderer?.thumbnail),
          author: text(value.shortBylineText), count: text(value.videoCountText) || value.videoCount || '' });
        continue;
      }
      visit(value);
    }
  };
  visit(data.contents || data);
  return result;
}
export function listing(data, endpoint = 'browse') {
  const channel = first(data, 'channelMetadataRenderer');
  const playlist = first(data, 'playlistMetadataRenderer');
  const header = first(data, 'pageHeaderViewModel');
  return { items: items(data), next: nextCursor(data, endpoint),
    title: channel?.title || playlist?.title || text(header?.title?.dynamicTextViewModel?.text) || '',
    description: channel?.description || playlist?.description || '',
    avatar: thumb(channel?.avatar),
    tabs: all(data, 'tabRenderer').filter(x => x.title && x.endpoint?.browseEndpoint).map(x => ({ title: x.title,
      selected: !!x.selected, id: x.endpoint.browseEndpoint.browseId, params: x.endpoint.browseEndpoint.params || '' })),
    filters: all(data, 'chipCloudChipRenderer').map(x => ({ title: text(x.text), selected: !!x.isSelected,
      cursor: cursor('browse', x.navigationEndpoint?.continuationCommand?.token),
      params: x.navigationEndpoint?.browseEndpoint?.params || '', id: x.navigationEndpoint?.browseEndpoint?.browseId || '' })),
    alerts: all(data, 'alertRenderer').map(x => text(x.text)),
  };
}
export function account(data) {
  const header = first(data, 'activeAccountHeaderRenderer');
  return header ? { signed_in: true, name: text(header.accountName), avatar: thumb(header.accountPhoto), handle: text(header.channelHandle) }
    : { signed_in: false, name: '', avatar: '', handle: '' };
}
export function video(page) {
  const p = page.player, initial = page.initial;
  const details = p?.videoDetails;
  if (!details) return null;
  const primary = first(initial, 'videoPrimaryInfoRenderer');
  const owner = first(initial, 'videoOwnerRenderer');
  const subscribe = first(initial, 'subscribeButtonRenderer');
  const section = all(initial, 'itemSectionRenderer').find(x => x.targetId === 'comments-section');
  return { id: details.videoId, title: details.title, description: details.shortDescription || '',
    duration: Number(details.lengthSeconds || 0), views: details.viewCount || '',
    author: details.author, channel_id: details.channelId, avatar: thumb(owner?.thumbnail),
    thumbnail: thumb(details.thumbnail), published: text(primary?.dateText),
    subscribers: text(owner?.subscriberCountText), subscribed: subscribe?.subscribed ?? null,
    like_status: first(initial, 'likeStatusEntity')?.likeStatus || 'UNKNOWN',
    likes: first(first(initial, 'segmentedLikeDislikeButtonViewModel')?.likeButtonViewModel, 'buttonViewModel')?.title || '',
    live: !!details.isLiveContent, playability: p?.playabilityStatus?.status || 'UNKNOWN',
    playability_message: p?.playabilityStatus?.reason || '',
    related: items(initial.contents?.twoColumnWatchNextResults?.secondaryResults || {}),
    related_next: nextCursor(initial.contents?.twoColumnWatchNextResults?.secondaryResults || {}, 'next'),
    comments_next: nextCursor(section, 'next', 'comments', details.videoId),
    captions: (p?.captions?.playerCaptionsTracklistRenderer?.captionTracks || []).map(x => ({ language: x.languageCode, name: text(x.name), automatic: x.kind === 'asr', url: x.baseUrl })),
  };
}
export function comments(data, videoId) {
  const entities = all(data, 'commentEntityPayload');
  const threads = all(data, 'commentThreadRenderer');
  const list = entities.map(x => {
    const thread = threads.find(t => all(t.commentViewModel || t.comment, 'commentKey').includes(x.key));
    return { kind: 'comment', id: x.properties?.commentId, text: text(x.properties?.content),
      author: x.author?.displayName || '', channel_id: x.author?.channelId || '', avatar: x.author?.avatarThumbnailUrl || '',
      published: x.properties?.publishedTime || '', likes: x.toolbar?.likeCountNotliked || '',
      reply_count: x.toolbar?.replyCount || '', replies: nextCursor(thread?.replies, 'next', 'comments', videoId),
    };
  });
  for (const x of all(data, 'commentRenderer')) list.push({ kind: 'comment', id: x.commentId, text: text(x.contentText), author: text(x.authorText),
    channel_id: x.authorEndpoint?.browseEndpoint?.browseId || '', avatar: thumb(x.authorThumbnail), published: text(x.publishedTimeText), likes: text(x.voteCount), replies: null });
  const top = [...all(data, 'appendContinuationItemsAction'), ...all(data, 'reloadContinuationItemsCommand')]
    .find(x => x.continuationItems?.some(y => y.continuationItemRenderer));
  const continuation = (top?.continuationItems || []).filter(x => x.continuationItemRenderer).at(-1);
  const create = first(data, 'createCommentEndpoint');
  return { items: list, next: nextCursor(continuation, 'next', 'comments', videoId),
    count: text(first(data, 'commentsHeaderRenderer')?.countText),
    can_comment: !!create, comment_params: create?.createCommentParams || null,
    requires_channel: !!first(data, 'zeroStepChannelCreationRenderer'),
    sort: (first(data, 'sortFilterSubMenuRenderer')?.subMenuItems || []).map(x => ({ title: x.title, selected: !!x.selected,
      cursor: cursor('next', x.serviceEndpoint?.continuationCommand?.token, 'comments', videoId) })),
  };
}
