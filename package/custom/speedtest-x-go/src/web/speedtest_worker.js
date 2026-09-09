/*
 * Speedtest-X / LibreSpeed worker interface (GNU LGPLv3).
 * Original interface: Federico Dossena, https://github.com/librespeed/speedtest/
 * Local measurement implementation: streaming download and acknowledged upload.
 * Mbps means application bytes * 8 / monotonic elapsed seconds / 1,000,000.
 */
(function (root) {
    "use strict";

    function createWorker(env) {
        var current = null;
        var sequence = 0;
        var state = initialState();

        function initialState() {
            return {
                testState: -1, dlStatus: "", ulStatus: "", pingStatus: "",
                jitterStatus: "", clientIp: "", dlProgress: 0, ulProgress: 0,
                pingProgress: 0, testId: null, phase: "idle", error: "", warning: "",
                measurement: null, measurements: {}, protocol: 3
            };
        }
        function emit() { env.postMessage(JSON.stringify(state)); }
        function now() { return env.performance.now(); }
        function mbps(bytes, seconds) {
            return seconds > 0 ? bytes * 8 / seconds / 1000000 : 0;
        }
        function number(settings, key, fallback, low, high, integer) {
            var value = settings[key] === undefined ? fallback : Number(settings[key]);
            if (!Number.isFinite(value) || value < low || value > high ||
                    (integer && !Number.isInteger(value))) {
                throw new Error("Invalid setting " + key + " (" + low + ".." + high + ")");
            }
            return value;
        }
        function configure(input) {
            if (!input || typeof input !== "object" || Array.isArray(input)) {
                throw new Error("Test settings must be a JSON object");
            }
            var order = String(input.test_order || "IP_D_U").toUpperCase();
            if (!/^[IPDU_]+$/.test(order)) throw new Error("Invalid test_order");
            return {
                order: order,
                dlSeconds: number(input, "time_dl_max", 15, 1, 120),
                ulSeconds: number(input, "time_ul_max", 15, 1, 120),
                dlStreams: number(input, "xhr_dlMultistream", 4, 1, 6, true),
                ulStreams: number(input, "xhr_ulMultistream", 4, 1, 6, true),
                dlWarmup: number(input, "time_dlGraceTime", 1, 0, 5),
                ulWarmup: number(input, "time_ulGraceTime", 2, 0, 5),
                uploadMiB: number(input, "xhr_ul_blob_megabytes", 16, 1, 32, true),
                downloadMiB: number(input, "garbagePhp_chunkSize", 50, 1, 50, true),
                countPing: number(input, "count_ping", 10, 1, 30, true),
                requestMs: number(input, "request_timeout_ms", 10000, 1, 60000),
                stallMs: number(input, "download_stall_ms", 5000, 1, 30000),
                drainMs: number(input, "upload_drain_ms", 5000, 1, 5000),
                urlHealth: input.url_health || "healthz",
                urlUploadSession: input.url_upload_session || "backend/upload-session",
                urlDl: input.url_dl || "backend/garbage.php",
                urlUl: input.url_ul || "backend/empty.php",
                urlPing: input.url_ping || "backend/empty.php",
                urlIp: input.url_getIp || "backend/getIP.php"
            };
            // Old time_auto, overheadCompensationFactor, browser quirks and
            // xhr_ignoreErrors deliberately do not alter accurate-mode results.
        }
        function timer(run, fn, ms) {
            var id = env.setTimeout(function () {
                run.timers.delete(id);
                fn();
            }, Math.max(0, ms));
            run.timers.add(id);
            return id;
        }
        function untimer(run, id) {
            if (id !== undefined) {
                env.clearTimeout(id);
                run.timers.delete(id);
            }
        }
        function active(run) { return current === run && !run.stopped; }
        function requestError(code, message) {
            var error = new Error(message);
            error.code = code;
            return error;
        }
        function ensure(run, record) {
            if (!active(run)) throw requestError("cancelled", "Request cancelled");
            if (record && record.closed) throw record.error || requestError("cancelled", "Request cancelled");
        }
        function closeRequest(record, reason) {
            if (record.closed) return;
            record.closed = true;
            record.error = reason || requestError("cancelled", "Request cancelled");
            // Deliver our explicit reason before transport abort reactions race it.
            record.reject(record.error);
            record.controller.abort();
            if (record.reader) {
                var reader = record.reader;
                record.reader = null;
                try {
                    Promise.resolve(reader.cancel()).catch(function () {}).then(function () {
                        try { reader.releaseLock(); } catch (_) {}
                    });
                } catch (_) {}
                try { reader.releaseLock(); } catch (_) {}
            }
        }
        function clean(run) {
            run.stopped = true;
            run.requests.forEach(function (record) { closeRequest(record); });
            run.timers.forEach(function (id) { env.clearTimeout(id); });
            run.timers.clear();
            run.cancel(new Error("Test cancelled"));
        }
        function url(run, base, query) {
            var value = new env.URL(String(base), env.location.href);
            if (value.protocol !== "http:" && value.protocol !== "https:") {
                throw new Error("Only HTTP(S) test endpoints are supported");
            }
            Object.keys(query || {}).forEach(function (key) {
                value.searchParams.set(key, String(query[key]));
            });
            value.searchParams.set("r", run.id + "-" + (++run.requestsMade));
            return value.href;
        }
        async function bounded(run, promise, ms, record, description) {
            var id;
            var limit = new Promise(function (_, reject) {
                id = timer(run, function () {
                    var error = requestError("request-timeout", description + " timed out");
                    reject(error);
                    if (record) closeRequest(record, error);
                }, ms);
            });
            try {
                // Request cancellation is already delivered through its record.
                // Do not retain one reaction on run.cancelled per request/chunk.
                return await Promise.race(record ? [promise, limit] : [promise, limit, run.cancelled]);
            } finally { untimer(run, id); }
        }
        async function request(run, base, options, consume, phase, timeoutMs) {
            ensure(run);
            var record = { controller: new env.AbortController(), reader: null, closed: false, lastProgress: now() };
            var interrupted = new Promise(function (_, reject) { record.reject = reject; });
            run.requests.add(record);
            if (phase) phase.requests.add(record);
            var watchdog;
            if (phase && phase.direction === "download") {
                function checkProgress() {
                    if (record.closed) return;
                    if (phase.deadline !== undefined && now() >= phase.deadline) {
                        phase.stop();
                        return;
                    }
                    var remaining = run.settings.stallMs - (now() - record.lastProgress);
                    if (remaining <= 0) closeRequest(record, requestError("download-stall", "Download stream timed out"));
                    else watchdog = timer(run, checkProgress, remaining);
                }
                watchdog = timer(run, checkProgress, run.settings.stallMs);
            }
            var operation = (async function () {
                var response = await env.fetch(base, Object.assign({
                    cache: "no-store", credentials: "same-origin", redirect: "error"
                }, options, { signal: record.controller.signal }));
                ensure(run, record);
                if (!response.ok) throw new Error("HTTP " + response.status + " from test server");
                return await consume(response, record);
            })();
            try {
                var result = Promise.race([operation, interrupted]);
                return await (timeoutMs ? bounded(run, result, timeoutMs, record, "Request") : result);
            } finally {
                untimer(run, watchdog);
                closeRequest(record);
                run.requests.delete(record);
                if (phase) phase.requests.delete(record);
            }
        }
        function readerFor(response, record) {
            if (!response.body || typeof response.body.getReader !== "function") {
                throw new Error("Streaming response unavailable; use a browser with fetch ReadableStream support");
            }
            record.reader = response.body.getReader();
            return record.reader;
        }
        async function textResponse(run, response, record, limit) {
            var reader = readerFor(response, record);
            var decoder = new env.TextDecoder();
            var size = 0, text = "";
            for (;;) {
                var chunk = await reader.read();
                ensure(run, record);
                if (chunk.done) break;
                size += chunk.value.byteLength;
                if (size > limit) throw new Error("Oversized test-server response");
                text += decoder.decode(chunk.value, { stream: true });
            }
            return text + decoder.decode();
        }
        async function small(run, base, query, options, phase, timeoutMs) {
            return request(run, url(run, base, query), options || {}, function (response, record) {
                return textResponse(run, response, record, 16384);
            }, phase, timeoutMs || run.settings.requestMs);
        }
        function measurement(phase, end) {
            var seconds = Math.max(0, end - phase.start) / 1000;
            var value = {
                direction: phase.direction, bytes: phase.bytes, elapsedSeconds: seconds,
                streams: phase.streams, warmup: phase.warmup, draining: !!phase.draining,
                mbps: mbps(phase.bytes, seconds), units: "Mbps", accounting: phase.direction === "upload" ? "server-acknowledged" : "stream-read"
            };
            if (phase.direction === "download") {
                value.interruptions = phase.interruptions;
                value.retries = phase.retries;
                value.retiredStreams = phase.retiredStreams;
                value.degraded = phase.interruptions > 0;
            }
            return value;
        }
        function update(phase, end) {
            state.measurement = measurement(phase, end);
            if (phase.warmup) return;
            var key = phase.direction === "download" ? "dl" : "ul";
            state[key + "Status"] = state.measurement.mbps.toFixed(2);
            state[key + "Progress"] = Math.min(1, Math.max(0, (end - phase.start) / phase.duration));
        }
        function pulse(run, phase) {
            var id;
            function tick() {
                if (!active(run) || phase.finished) return;
                update(phase, now());
                emit();
                id = timer(run, tick, 200);
            }
            id = timer(run, tick, 200);
            return function () { untimer(run, id); };
        }
        async function checkServer(run) {
            state.phase = "check";
            emit();
            var info = JSON.parse(await small(run, run.settings.urlHealth));
            if (!info || info.protocol !== 3 || info.upload_session !== true)
                throw new Error("Incompatible speed-test backend: protocol 3 with upload sessions is required; refresh the page");
            if (info.max_download_mib !== undefined) {
                if (!Number.isInteger(info.max_download_mib) || info.max_download_mib < 1) {
                    throw new Error("Invalid server download limit");
                }
                run.settings.downloadMiB = Math.min(run.settings.downloadMiB, info.max_download_mib);
            }
            if (info.max_streams !== undefined && (!Number.isInteger(info.max_streams) ||
                    info.max_streams < Math.max(run.settings.dlStreams, run.settings.ulStreams))) {
                throw new Error("Server has insufficient concurrent stream capacity");
            }
        }
        async function getIp(run) {
            state.phase = "ip";
            var body = await small(run, run.settings.urlIp, { isp: true });
            ensure(run);
            try {
                var info = JSON.parse(body);
                state.clientIp = String(info.processedString || info.ip || "");
            } catch (_) { state.clientIp = body.trim(); }
        }
        async function ping(run) {
            state.testState = 2;
            state.phase = "ping";
            var samples = [], differences = [];
            for (var i = 0; i <= run.settings.countPing; i++) {
                var start = now();
                await small(run, run.settings.urlPing);
                ensure(run);
                var elapsed = now() - start;
                if (i === 0) continue;
                samples.push(elapsed);
                if (samples.length > 1) differences.push(Math.abs(elapsed - samples[samples.length - 2]));
                state.pingStatus = (samples.reduce(function (a, b) { return a + b; }, 0) / samples.length).toFixed(2);
                state.jitterStatus = (differences.length ? differences.reduce(function (a, b) { return a + b; }, 0) / differences.length : 0).toFixed(2);
                state.pingProgress = i / run.settings.countPing;
                emit();
            }
        }
        async function download(run) {
            var settings = run.settings;
            var phase = {
                direction: "download", streams: settings.dlStreams, bytes: 0,
                start: now(), duration: settings.dlSeconds * 1000, warmup: true,
                ended: false, finished: false, requests: new Set(),
                lastProgress: now(), interruptions: 0, retries: 0, retiredStreams: 0
            };
            state.testState = 1;
            state.phase = "download-warmup";
            var deadlineTimer, warmupTimer, progressTimer;
            function stop() {
                phase.ended = true;
                var reason = requestError("download-window-ended", "Download window ended");
                phase.requests.forEach(function (record) { closeRequest(record, reason); });
            }
            phase.stop = stop;
            function checkGlobalProgress() {
                if (!active(run) || phase.ended || phase.finished) return;
                // A completed fixed window wins even if an idle timer is due too.
                if (phase.deadline !== undefined && now() >= phase.deadline) { stop(); return; }
                var remaining = settings.stallMs - (now() - phase.lastProgress);
                if (remaining <= 0) {
                    phase.fatalError = requestError("download-no-progress", "Download timed out: no data received on any stream");
                    phase.requests.forEach(function (record) { closeRequest(record, phase.fatalError); });
                    return;
                }
                progressTimer = timer(run, checkGlobalProgress, remaining);
            }
            function warn() {
                state.warning = "下载连接发生 " + phase.interruptions + " 次停滞，已重连 " + phase.retries +
                    " 次" + (phase.retiredStreams ? "，停止使用 " + phase.retiredStreams + " 条异常连接" : "") +
                    "；结果包含停滞时间，可能低于链路能力。";
                emit();
            }
            function begin() {
                if (!active(run) || phase.ended) return;
                phase.warmup = false;
                phase.bytes = 0;
                phase.start = now();
                phase.deadline = phase.start + phase.duration;
                state.phase = "download";
                update(phase, phase.start);
                emit();
                deadlineTimer = timer(run, stop, phase.duration);
            }
            if (settings.dlWarmup) warmupTimer = timer(run, begin, settings.dlWarmup * 1000);
            else begin();
            progressTimer = timer(run, checkGlobalProgress, settings.stallMs);
            var stopPulse = pulse(run, phase);
            async function stream() {
                var retries = 0;
                while (active(run) && !phase.ended) {
                    try {
                        await request(run, url(run, settings.urlDl, { ckSize: settings.downloadMiB }), {}, async function (response, record) {
                            var reader = readerFor(response, record), received = 0;
                            var length = response.headers.get("content-length");
                            var expected = Number(length);
                            if (!length || !/^\d+$/.test(length) || !Number.isSafeInteger(expected) || expected <= 0) {
                                throw new Error("Download response is missing a valid Content-Length");
                            }
                            for (;;) {
                                // A single watchdog per stream observes lastProgress;
                                // no timers, aggregate buffers or cancellation reactions per chunk.
                                var chunk = await reader.read();
                                ensure(run, record);
                                if (!phase.warmup && now() >= phase.deadline) { stop(); return; }
                                if (chunk.done) break;
                                received += chunk.value.byteLength;
                                if (chunk.value.byteLength) phase.lastProgress = record.lastProgress = now();
                                if (received > expected) throw new Error("Download response exceeded Content-Length");
                                if (!phase.warmup) phase.bytes += chunk.value.byteLength;
                            }
                            if (!received) throw new Error("Empty download response");
                            if (received !== expected) throw new Error("Truncated download response");
                        }, phase, (settings.dlWarmup + settings.dlSeconds) * 1000 + settings.stallMs);
                    } catch (error) {
                        if (!active(run)) throw error;
                        if (phase.fatalError) throw phase.fatalError;
                        if (error.code === "download-window-ended" && phase.ended) return;
                        // Only our own idle watchdog is recoverable. HTTP, framing,
                        // browser/network and unknown errors must not become a pass.
                        if (error.code !== "download-stall" || phase.ended) throw error;
                        phase.interruptions++;
                        if (retries >= 2) {
                            phase.retiredStreams++;
                            warn();
                            return;
                        }
                        retries++;
                        phase.retries++;
                        warn();
                    }
                }
            }
            try {
                await Promise.all(Array.from({ length: phase.streams }, stream));
                ensure(run);
                if (phase.fatalError) throw phase.fatalError;
                if (!phase.ended) throw new Error("Download failed: every stream exhausted its retry budget");
                if (!phase.bytes) throw new Error("No measured download data received");
                // Cleanup scheduling delay is outside the fixed counting window.
                update(phase, phase.deadline);
                state.dlProgress = 1;
                state.measurements.download = state.measurement;
            } finally {
                phase.finished = true;
                stop();
                stopPulse();
                untimer(run, warmupTimer);
                untimer(run, deadlineTimer);
                untimer(run, progressTimer);
            }
        }
        function uploadBlob(settings) {
            var data = new Uint8Array(settings.uploadMiB * 1024 * 1024);
            if (env.crypto && typeof env.crypto.getRandomValues === "function") {
                for (var i = 0; i < data.length; i += 65536) env.crypto.getRandomValues(data.subarray(i, i + 65536));
            } else {
                for (var j = 0; j < data.length; j++) data[j] = Math.floor(Math.random() * 256);
            }
            return new env.Blob([data], { type: "application/octet-stream" });
        }
        async function releaseUploadSession(run) {
            if (!run.uploadSession || run.releasingSession) return run.releasingSession;
            var id = run.uploadSession;
            run.uploadSession = null;
            // Cancellation has already closed run.requests. This final control
            // request has its own bounded lifetime, including on user abort.
            run.releasingSession = (async function () {
                var controller = new env.AbortController(), timeout;
                try {
                    await Promise.race([
                        env.fetch(url(run, run.settings.urlUploadSession, { id: id }), {
                            method: "DELETE", cache: "no-store", credentials: "same-origin",
                            redirect: "error", signal: controller.signal
                        }),
                        new Promise(function (resolve) { timeout = env.setTimeout(resolve, 1000); })
                    ]);
                } catch (_) { /* server expiry also bounds abandoned sessions */ }
                finally { controller.abort(); env.clearTimeout(timeout); }
            })();
            return run.releasingSession;
        }
        async function upload(run) {
            var settings = run.settings;
            var blob = uploadBlob(settings);
            // HTTP/1.1 browsers commonly have six connections per origin. Leave
            // one for the authoritative counter, even when download uses six.
            var phase = { direction: "upload", streams: Math.min(settings.ulStreams, 5), requests: new Set(), ended: false };
            var controls = { direction: "control", requests: new Set() };
            var totalMs = (settings.ulWarmup + settings.ulSeconds) * 1000;
            var lastBytes = 0, lastElapsed = 0, lastRank = 0, lastRemaining = totalMs;
            var earliestDone;
            var jobs = [], monitor;
            state.testState = 3;
            state.phase = "upload-warmup";
            state.ulStatus = "0.00";
            emit();
            function snapshot(body, creating) {
                var value;
                try { value = JSON.parse(body); } catch (_) { throw new Error("Invalid upload counter JSON"); }
                var ranks = { waiting: 0, warmup: 1, measuring: 2, done: 3 };
                if (!value || !/^[a-f0-9]{32}$/.test(value.id) ||
                        (!creating && value.id !== run.uploadSession) || (creating && value.state !== "waiting") ||
                        !Object.prototype.hasOwnProperty.call(ranks, value.state) ||
                        !Number.isSafeInteger(value.bytes) || value.bytes < lastBytes ||
                        !Number.isFinite(value.elapsed_ms) || value.elapsed_ms < lastElapsed ||
                        value.elapsed_ms > settings.ulSeconds * 1000 ||
                        value.duration_ms !== settings.ulSeconds * 1000 ||
                        value.warmup_ms !== settings.ulWarmup * 1000 ||
                        !Number.isSafeInteger(value.remaining_ms) || value.remaining_ms < 0 || value.remaining_ms > lastRemaining ||
                        ranks[value.state] < lastRank ||
                        (value.state === "waiting" && value.remaining_ms !== totalMs) ||
                        (value.state === "warmup" && value.remaining_ms < value.duration_ms) ||
                        (value.state === "measuring" && (value.elapsed_ms >= value.duration_ms ||
                            Math.abs(value.remaining_ms - (value.duration_ms - value.elapsed_ms)) > 1)) ||
                        (value.state === "done" && (value.elapsed_ms !== value.duration_ms || value.remaining_ms !== 0)) ||
                        (value.state === "done" && earliestDone !== undefined && now() + 20 < earliestDone) ||
                        ((value.state === "waiting" || value.state === "warmup") && (value.bytes !== 0 || value.elapsed_ms !== 0))) {
                    throw new Error("Invalid or inconsistent upload measurement");
                }
                lastBytes = value.bytes; lastElapsed = value.elapsed_ms; lastRank = ranks[value.state]; lastRemaining = value.remaining_ms;
                return value;
            }
            function publish(value) {
                var elapsed = value.elapsed_ms / 1000;
                var measured = {
                    direction: "upload", bytes: value.bytes, elapsedSeconds: elapsed,
                    streams: phase.streams, requestedStreams: settings.ulStreams,
                    warmup: value.state === "waiting" || value.state === "warmup", draining: false,
                    mbps: mbps(value.bytes, elapsed), units: "Mbps", accounting: "server-received-fixed-window"
                };
                state.phase = measured.warmup ? "upload-warmup" : "upload";
                state.measurement = measured;
                state.ulProgress = value.elapsed_ms / value.duration_ms;
                state.ulStatus = measured.mbps.toFixed(2);
                emit();
                return measured;
            }
            async function stream() {
                while (active(run) && !phase.ended) {
                    try {
                        var body = await small(run, settings.urlUl, { ack: 1, session: run.uploadSession },
                            { method: "POST", body: blob }, phase, totalMs + settings.requestMs);
                        ensure(run);
                        var ack;
                        try { ack = JSON.parse(body); } catch (_) { throw new Error("Invalid upload acknowledgement JSON"); }
                        if (!ack || !Number.isSafeInteger(ack.bytes) || ack.bytes !== blob.size)
                            throw new Error("Upload acknowledgement byte count mismatch");
                        // ACK is a transport-integrity check, NOT the numerator.
                        // A partly received POST at the deadline is in the server
                        // counter even if the remaining body/ACK is cancelled.
                    } catch (error) {
                        if (phase.ended && active(run) && error.code === "upload-window-ended") return;
                        throw error;
                    }
                }
            }
            try {
                var created = snapshot(await small(run, settings.urlUploadSession, {
                    warmup_ms: settings.ulWarmup * 1000, duration_ms: settings.ulSeconds * 1000
                }, { method: "POST" }, controls), true);
                run.uploadSession = created.id;
                publish(created);
                earliestDone = now() + totalMs;
                jobs = Array.from({ length: phase.streams }, stream);
                monitor = (async function () {
                    while (active(run) && !phase.ended) {
                        await Promise.race([new Promise(function (resolve) { timer(run, resolve, 500); }), run.cancelled]);
                        if (phase.ended) return;
                        var value = snapshot(await small(run, settings.urlUploadSession, { id: run.uploadSession }, {}, controls));
                        ensure(run);
                        if (phase.ended) return;
                        var measured = publish(value);
                        if (value.state === "done") {
                            if (!value.bytes) throw new Error("No measured upload data received by the router");
                            state.measurements.upload = measured;
                            phase.ended = true;
                            phase.requests.forEach(function (record) {
                                closeRequest(record, requestError("upload-window-ended", "Upload window ended"));
                            });
                            return;
                        }
                    }
                })();
                await bounded(run, Promise.race([monitor, Promise.all(jobs).then(function () {
                    if (!phase.ended) throw new Error("All upload streams stopped before measurement completed");
                })]), totalMs + settings.requestMs, null, "Upload measurement");
                // Do not hide a transport/protocol failure racing the final
                // counter. Only our explicit window-end cancellation is benign.
                await Promise.all(jobs);
                ensure(run);
                if (!state.measurements.upload) throw new Error("Upload counter did not complete");
                state.ulProgress = 1;
            } finally {
                phase.ended = true;
                phase.requests.forEach(function (record) { closeRequest(record); });
                controls.requests.forEach(function (record) { closeRequest(record); });
                await Promise.allSettled(jobs.concat(monitor || []));
                await releaseUploadSession(run);
            }
        }
        async function execute(run) {
            await checkServer(run);
            var completed = new Set();
            for (var item of run.settings.order) {
                ensure(run);
                if (item === "_") {
                    await Promise.race([new Promise(function (resolve) { timer(run, resolve, 1000); }), run.cancelled]);
                    continue;
                }
                if (completed.has(item)) continue;
                completed.add(item);
                if (item === "I") await getIp(run);
                if (item === "P") await ping(run);
                if (item === "D") await download(run);
                if (item === "U") await upload(run);
            }
        }
        function start(input) {
            if (current && active(current)) return;
            state = initialState();
            state.testState = 0;
            state.phase = "check";
            var run = { id: ++sequence, requestsMade: 0, stopped: false, requests: new Set(), timers: new Set() };
            run.cancelled = new Promise(function (_, reject) { run.cancel = reject; });
            run.cancelled.catch(function () {});
            current = run;
            run.finished = (async function () {
                try {
                    if (!env.performance || typeof env.performance.now !== "function" ||
                            typeof env.fetch !== "function" || typeof env.AbortController !== "function" ||
                            typeof env.ReadableStream !== "function" || typeof env.TextDecoder !== "function") {
                        throw new Error("Accurate testing requires fetch, ReadableStream, AbortController and a monotonic clock");
                    }
                    run.settings = configure(input);
                    await execute(run);
                    ensure(run);
                    state.testState = 4;
                    state.phase = "done";
                } catch (error) {
                    if (!active(run)) return;
                    if (state.testState === 1) state.dlStatus = "Fail";
                    if (state.testState === 3) state.ulStatus = "Fail";
                    state.testState = 5;
                    state.phase = "error";
                    state.error = error && error.message ? error.message : String(error);
                } finally {
                    if (current === run && !run.stopped) {
                        clean(run);
                        emit();
                    }
                }
            })();
        }
        function handleMessage(message) {
            if (typeof message !== "string") return;
            var command = message.split(" ", 1)[0];
            if (command === "status") { if (!current || !current.cancelPending) emit(); return; }
            if (command === "abort") {
                if (!current || !active(current)) return;
                var cancelledRun = current;
                cancelledRun.cancelPending = true;
                clean(cancelledRun);
                state.testState = 5;
                state.phase = "cancelled";
                state.error = "";
                Promise.resolve(releaseUploadSession(cancelledRun)).then(function () {
                    cancelledRun.cancelPending = false;
                    if (current === cancelledRun) emit();
                });
                return;
            }
            if (command === "start") {
                if (current && active(current)) return;
                try { start(message.slice(5).trim() ? JSON.parse(message.slice(5)) : {}); }
                catch (error) {
                    state = initialState();
                    state.testState = 5;
                    state.phase = "error";
                    state.error = "Invalid settings JSON: " + error.message;
                    emit();
                }
            }
        }
        return {
            handleMessage: handleMessage,
            snapshot: function () { return JSON.parse(JSON.stringify(state)); },
            finished: function () { return current ? current.finished : Promise.resolve(); },
            diagnostics: function () { return current ? { requests: current.requests.size, timers: current.timers.size } : { requests: 0, timers: 0 }; }
        };
    }
    if (typeof module !== "undefined" && module.exports) module.exports = { createWorker: createWorker };
    else {
        var worker = createWorker(root);
        root.addEventListener("message", function (event) { worker.handleMessage(event.data); });
    }
})(typeof self !== "undefined" ? self : globalThis);
