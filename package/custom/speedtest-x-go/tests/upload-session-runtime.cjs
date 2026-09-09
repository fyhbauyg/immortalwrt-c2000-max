'use strict';

// Independent protocol-3 browser/server model. No sockets, wall clock or files.
const assert = require('node:assert/strict');
const { ReviewRuntime } = require('./review-runtime.cjs');
class UploadSessionRuntime extends ReviewRuntime {
  constructor(options = {}) {
    super(options);
    this.sessions = new Map();
    this.allSessions = [];
    this.sessionReceives = [];
    this.deleted = [];
    this.activePosts = 0;
    this.peakPosts = 0;
    this.sessionNumber = 0;
    this.polls = 0;
  }
  snapshotSession(session) {
    const value = { id: session.id, state: 'waiting', bytes: session.bytes,
      elapsed_ms: 0, warmup_ms: session.warmup, duration_ms: session.duration,
      remaining_ms: session.warmup + session.duration };
    if (session.start !== null) {
      const start = session.start + session.warmup;
      const end = start + session.duration;
      value.remaining_ms = Math.max(0, Math.ceil(end - this.now));
      if (this.now < start) value.state = 'warmup';
      else if (this.now < end) { value.state = 'measuring'; value.elapsed_ms = this.now - start; }
      else { value.state = 'done'; value.elapsed_ms = session.duration; }
    }
    return value;
  }
  response(status, data, signal, delay = 0) {
    const bytes = new TextEncoder().encode(typeof data === 'string' ? data : JSON.stringify(data));
    return { ok: status >= 200 && status < 300, status, headers: { get: () => null },
      body: { getReader: () => {
        let used = false;
        return { read: () => {
          if (used) return Promise.resolve({ done: true });
          used = true;
          return this.later(delay, signal, () => ({ done: false, value: bytes }));
        }, cancel: async () => {}, releaseLock() {} };
      } } };
  }
  fetch(url, init = {}) {
    const parsed = new URL(url);
    const control = parsed.pathname.endsWith('/upload-session');
    const post = parsed.pathname.endsWith('/empty.php') && init.method === 'POST';
    if (!control && !post) return super.fetch(url, init);
    const req = { url: parsed, time: this.now, init, aborted: false, settled: false };
    this.requests.push(req);
    let completed = false;
    const finish = () => { if (!completed) { completed = true; if (post) this.activePosts--; } };
    init.signal?.addEventListener('abort', () => { req.aborted = true; finish(); }, { once: true });
    if (control && init.method === 'POST') {
      return this.later(this.options.createDelay ?? 1, init.signal, () => {
        const id = (++this.sessionNumber).toString(16).padStart(32, '0');
        const session = { id, warmup: Number(parsed.searchParams.get('warmup_ms')),
          duration: Number(parsed.searchParams.get('duration_ms')), bytes: 0, start: null, closed: false };
        this.sessions.set(id, session); this.allSessions.push(session);
        req.settled = true;
        const value = this.options.mutateCreate?.(this.snapshotSession(session)) ?? this.snapshotSession(session);
        return this.response(this.options.createStatus ?? 200, value, init.signal);
      });
    }
    if (control && init.method === 'DELETE') {
      const id = parsed.searchParams.get('id');
      this.deleted.push(id);
      const session = this.sessions.get(id);
      if (session) session.closed = true;
      this.sessions.delete(id);
      return this.later(this.options.deleteDelay ?? 1, init.signal, () => {
        req.settled = true;
        return this.response(204, '', init.signal);
      }, !!this.options.ignoreDeleteAbort);
    }
    if (control) {
      const session = this.sessions.get(parsed.searchParams.get('id'));
      const index = ++this.polls;
      return this.later(this.options.pollDelay ?? 1, init.signal, () => {
        req.settled = true;
        if (!session) return this.response(404, '', init.signal);
        const value = this.options.mutatePoll?.(this.snapshotSession(session), index, session) ?? this.snapshotSession(session);
        return this.response(this.options.pollStatus ?? 200, value, init.signal);
      }, !!this.options.ignorePollAbort);
    }
    assert.equal(parsed.searchParams.get('ack'), '1');
    const session = this.sessions.get(parsed.searchParams.get('session'));
    assert.ok(session, 'upload is tied to a created session');
    this.blobs.add(init.body);
    req.size = init.body.size;
    req.session = session.id;
    req.received = 0;
    this.activePosts++;
    this.peakPosts = Math.max(this.peakPosts, this.activePosts);
    const options = { ...this.options };
    return (async () => {
      try {
        if (options.uploadStatus || options.uploadError) {
          await this.later(1, init.signal, () => {});
          if (options.uploadError) throw new Error('upload network failure');
          return this.response(options.uploadStatus, '', init.signal);
        }
        while (req.received < req.size) {
          await this.later(options.chunkMs ?? 50, init.signal, () => {
            const n = Math.min(options.uploadChunkBytes ?? 128 * 1024, req.size - req.received);
            req.received += n;
            let counted = false;
            if (n > 0 && !session.closed) {
              if (session.start === null) session.start = this.now;
              const begin = session.start + session.warmup;
              if (this.now >= begin && this.now < begin + session.duration) {
                session.bytes += n; counted = true;
              }
            }
            this.sessionReceives.push({ time: this.now, bytes: n, request: req, session: session.id, counted });
          }, !!options.ignoreUploadAbort);
        }
        await this.later(options.uploadAckDelay ?? 1, init.signal, () => {}, !!options.ignoreUploadAbort);
        const data = options.ackBody ?? { bytes: options.ackBytes ?? req.size };
        if (data.bytes === req.size) this.acknowledgedBytes += req.size;
        req.settled = true;
        return this.response(200, data, init.signal, options.ackBodyDelay ?? 0);
      } finally { finish(); }
    })();
  }
}
module.exports = { UploadSessionRuntime };
