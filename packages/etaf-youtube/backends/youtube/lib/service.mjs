import { fail } from '../vendor/render.mjs';
import { account, listing, video, comments, all, first, text, cursor } from './response.mjs';

const FEEDS = { home: 'FEwhat_to_watch', subscriptions: 'FEsubscriptions', history: 'FEhistory', liked: 'VLLL', 'watch-later': 'VLWL' };
export function videoId(value) {
  let id = value || '';
  if (/^https:\/\//.test(id)) {
    const url = new URL(id);
    if (url.hostname === 'youtu.be') id = url.pathname.slice(1);
    else if (['youtube.com', 'www.youtube.com', 'm.youtube.com'].includes(url.hostname)) id = url.searchParams.get('v') || url.pathname.split('/').at(-1);
  }
  if (!/^[A-Za-z0-9_-]{11}$/.test(id)) fail('usage', '需要 11 位 YouTube 视频 ID 或视频链接', 'pi-skill youtube help video');
  return id;
}
export async function check(s) {
  const result = account(await s.request('account/account_menu'));
  if (!result.signed_in) fail('auth', 'YouTube 没有返回当前账号', 'pi-skill youtube login', { needHuman: true });
  return result;
}
export async function feed(s, name) {
  if (FEEDS[name]) return listing(await s.request('browse', { browseId: FEEDS[name] }));
  if (name === 'playlists') return listing((await s.page('/feed/playlists')).initial);
  if (name === 'shorts') {
    const page = await s.page('/shorts');
    const id = page.initial?.replacementEndpoint?.reelWatchEndpoint?.videoId;
    const current = id ? await details(s, id) : video(page);
    if (!current) fail('external', 'YouTube Shorts 返回格式已变化，未取得短视频', 'pi-skill youtube feed home');
    return { title: 'Shorts', items: [{ ...current, kind: 'short' }],
      next: cursor('reel/reel_watch_sequence', page.initial.sequenceContinuation, 'shorts') };
  }
  if (name === 'live') return listing(await s.request('search', { query: '直播', params: 'EgJAAQ%3D%3D' }), 'search');
  fail('usage', `未知列表 ${name}`, 'pi-skill youtube help feed');
}
export async function search(s, query, filter = 'all') {
  const filters = { all: '', videos: 'EgIQAQ%3D%3D', channels: 'EgIQAg%3D%3D', playlists: 'EgIQAw%3D%3D', live: 'EgJAAQ%3D%3D' };
  if (!Object.hasOwn(filters, filter) || !query?.trim()) fail('usage', '搜索需要关键词和有效筛选类型', 'pi-skill youtube help search');
  return listing(await s.request('search', { query, ...(filters[filter] ? { params: filters[filter] } : {}) }), 'search');
}
export async function browse(s, id, params = '') {
  if (/^@[A-Za-z0-9_.\p{L}\p{N}-]+$/u.test(id)) return listing((await s.page(`/${encodeURIComponent(id).replace('%40', '@')}`)).initial);
  if (!/^(UC|PL|UU|VL)[A-Za-z0-9_-]+$/.test(id) && !['WL', 'LL'].includes(id)) fail('usage', '需要频道 ID、@handle 或播放列表 ID', 'pi-skill youtube help browse');
  const browseId = id.startsWith('UC') || id.startsWith('VL') ? id : `VL${id}`;
  return listing(await s.request('browse', { browseId, ...(params ? { params } : {}) }));
}
export async function details(s, id) {
  const result = video(await s.page(`/watch?v=${videoId(id)}`));
  if (!result) fail('notfound', '视频不可用或当前账号没有观看权限', 'pi-skill youtube search <关键词>');
  return result;
}
export function decodeCursor(value) {
  let c;
  try { c = JSON.parse(Buffer.from(value, 'base64url').toString()); } catch { /* rejected below */ }
  if (c?.v !== 1 || !['browse', 'search', 'next', 'reel/reel_watch_sequence'].includes(c.endpoint) || !['items', 'comments', 'shorts'].includes(c.kind) || typeof c.token !== 'string' || !c.token || c.token.length > 24000)
    fail('usage', '无效的分页标记，请重新打开列表', 'pi-skill youtube feed home');
  return c;
}
export async function more(s, encoded) {
  const c = decodeCursor(encoded);
  const data = await s.request(c.endpoint, c.kind === 'shorts' ? { sequenceParams: c.token } : { continuation: c.token });
  if (c.kind === 'shorts') return {
    items: (data.entries || []).map(x => first(x, 'reelWatchEndpoint')?.videoId).filter(Boolean).map(id => ({
      kind: 'short', id, title: 'Shorts', needs_details: true, thumbnail: `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
      duration: 'Shorts', author: '', channel_id: '', views: '', published: '' })),
    next: cursor(c.endpoint, data.continuationEndpoint?.continuationCommand?.token, 'shorts'),
  };
  return c.kind === 'comments' ? comments(data, c.video_id) : listing(data, c.endpoint);
}
export async function discussion(s, id) {
  const current = await details(s, id);
  if (!current.comments_next) return { items: [], next: null, can_comment: false, message: '此视频的评论已关闭或不可用' };
  return more(s, current.comments_next);
}

/** Mutations are never retried. The caller must explicitly supply --yes. */
export async function action(s, operation, target, flags) {
  const videoActions = ['like', 'dislike', 'unrate', 'save', 'comment'];
  if (videoActions.includes(operation)) target = videoId(target);
  else if (!['subscribe', 'unsubscribe'].includes(operation)) fail('usage', `未知动作 ${operation}`, 'pi-skill youtube help action');
  if (['subscribe', 'unsubscribe'].includes(operation) && !/^UC[A-Za-z0-9_-]{22}$/.test(target)) fail('usage', '订阅操作需要频道 ID', 'pi-skill youtube help action');
  if (operation === 'comment' && !flags.text?.trim()) fail('usage', '评论需要 --text', 'pi-skill youtube help action');
  if (operation === 'save' && flags.playlist && !/^(WL|PL[A-Za-z0-9_-]+)$/.test(flags.playlist))
    fail('usage', '保存目标必须是稍后观看 WL 或自己的播放列表 ID', 'pi-skill youtube feed playlists');
  const preview = { operation, target, text: flags.text || null, playlist: flags.playlist || null };
  if (!flags.yes || flags['dry-run']) return { ...preview, status: 'preview', committed: false, verified: false };
  let endpoint, body, expected, verify;
  if (['like', 'dislike', 'unrate'].includes(operation)) {
    const page = await s.page(`/watch?v=${target}`);
    expected = { like: 'LIKE', dislike: 'DISLIKE', unrate: 'INDIFFERENT' }[operation];
    if (video(page)?.like_status === expected) return { ...preview, status: 'unchanged', committed: false, verified: true };
    const ep = all(page.initial, 'likeEndpoint').find(x => x.status === expected);
    if (!ep) fail('blocked', '此账号不能对该视频评分', 'pi-skill youtube check');
    endpoint = `like/${{ like: 'like', dislike: 'dislike', unrate: 'removelike' }[operation]}`;
    const key = { like: 'likeParams', dislike: 'dislikeParams', unrate: 'removeLikeParams' }[operation];
    body = { target: ep.target, params: ep[key] };
    verify = async () => (await details(s, target)).like_status === expected;
  } else if (operation === 'subscribe' || operation === 'unsubscribe') {
    const raw = await s.request('browse', { browseId: target });
    const button = first(raw, 'subscribeButtonRenderer');
    const subscribed = button?.subscribed;
    expected = operation === 'subscribe';
    if (subscribed === expected) return { ...preview, status: 'unchanged', committed: false, verified: true };
    const ep = first(raw, expected ? 'subscribeEndpoint' : 'unsubscribeEndpoint');
    if (!ep) fail('blocked', '此账号不能更改该频道的订阅', 'pi-skill youtube check');
    endpoint = `subscription/${operation}`;
    body = { channelIds: [target], ...(ep.params ? { params: ep.params } : {}) };
    verify = async () => first(await s.request('browse', { browseId: target }), 'subscribeButtonRenderer')?.subscribed === expected;
  } else if (operation === 'save') {
    const playlist = flags.playlist || 'WL';
    if (!/^(WL|PL[A-Za-z0-9_-]+)$/.test(playlist)) fail('usage', '保存目标必须是稍后观看 WL 或自己的播放列表 ID', 'pi-skill youtube feed playlists');
    endpoint = 'browse/edit_playlist';
    body = { playlistId: playlist, actions: [{ action: 'ACTION_ADD_VIDEO', addedVideoId: target }] };
    verify = async response => response.status === 'STATUS_SUCCEEDED'
      && (first(response, 'playlistEditResults') || []).some(x => first(x, 'videoId') === target);
  } else if (operation === 'comment') {
    const current = await discussion(s, target);
    if (!current.can_comment) fail('blocked', current.requires_channel ? '当前账号尚未创建 YouTube 频道；请先在网页创建频道后再评论' : '此视频不能发表评论', 'pi-skill youtube login', { needHuman: true });
    endpoint = 'comment/create_comment';
    body = { createCommentParams: current.comment_params, commentText: flags.text };
    verify = async response => all(response, 'commentEntityPayload').some(x => text(x.properties?.content) === flags.text)
      || all(response, 'commentRenderer').some(x => text(x.contentText) === flags.text);
  }
  const response = await s.request(endpoint, body);
  const errors = all(response, 'alertRenderer').filter(x => x.type === 'ERROR');
  if (errors.length) fail('external', errors.map(x => text(x.text)).join('; '), 'pi-skill youtube check');
  let verified = false, verificationError = '';
  try { verified = await verify(response); } catch (error) { verificationError = error.message; }
  return { ...preview, status: verified ? 'confirmed' : 'submitted', committed: verified ? true : null, verified,
    ...(verified ? {} : { warning: '请求已提交，但回读未确认。不要自动重发。', verification_error: verificationError }) };
}
