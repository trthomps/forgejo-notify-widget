// Run: node kde/test/forgejo.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");
const src = fs.readFileSync(path.join(__dirname, "../package/contents/code/forgejo.js"), "utf8")
    .replace(/^\.pragma library.*$/m, "");
const F = {};
vm.runInNewContext(src + "\nObject.assign(F, this);", { F });

const now = Date.parse("2026-11-21T12:00:00Z");
let pass = 0;
// Objects come from another VM realm, so compare by value.
const eq = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b));
function test(name, fn) {
    try { fn(); pass++; } catch (e) { console.error("FAIL " + name); throw e; }
}

const raw = (over = {}) => Object.assign({
    id: 1, unread: true, pinned: false, updated_at: "2026-11-21T11:00:00.123+01:00",
    repository: { full_name: "travis/app", html_url: "https://git.example/travis/app" },
    subject: { title: "Fix the thing", type: "Pull", state: "open",
        url: "https://git.example/api/v1/repos/travis/app/issues/580",
        html_url: "https://git.example/travis/app/pulls/580",
        latest_comment_url: "", latest_comment_html_url: "" },
}, over);

const config = (over = {}) => F.filtersFromConfig(Object.assign({
    filterTypes: F.TYPES.join(","), filterHideClosed: false, filterHideMerged: false, filterHideDrafts: false,
    filterOnlyInvolved: false, filterIncludeRepos: "", filterExcludeRepos: "", filterExcludeAuthors: "",
    filterExcludeCommenters: "", filterExcludeLabels: "", filterExcludeTitles: "",
}, over));

test("parse threads", () => {
    const ts = F.parseThreads(JSON.stringify([raw(), { id: "bad" }, raw({ id: 2, subject: { type: "Weird" } })]));
    assert.strictEqual(ts.length, 2);
    const t = ts[0];
    assert.strictEqual(t.updatedAt, Date.parse("2026-11-21T10:00:00Z"));
    assert.strictEqual(t.latestCommentURL, null);
    assert.strictEqual(F.number(t), "#580");
    assert.strictEqual(F.webURL(t), "https://git.example/travis/app/pulls/580");
    assert.strictEqual(ts[1].type, "Other");
    assert.strictEqual(F.number(ts[1]), "");
    assert.strictEqual(F.webURL(ts[1]), "https://git.example/travis/app");
    assert.throws(() => F.parseThreads("{}"), e => e.kind === "decoding");
});

test("glob", () => {
    assert.ok(F.globMatches("*bot", "Renovate-Bot"));
    assert.ok(F.globMatches("travis/*", "travis/app"));
    assert.ok(!F.globMatches("travis/*", "other/travis"));
    assert.ok(F.globMatches("chore(deps)*", "chore(deps): bump"));
    assert.ok(F.globMatches("a?c", "abc"));
    eq(F.patterns(" a, b\n\nc ,"), ["a", "b", "c"]);
});

test("cheap filters", () => {
    const t = F.parseThread(raw());
    assert.strictEqual(F.hiddenReason(config(), t, null, "me"), null);
    assert.strictEqual(F.hiddenReason(config({ filterTypes: "Issue" }), t, null, "me"), "Pull requests");
    assert.strictEqual(F.hiddenReason(config({ filterExcludeRepos: "travis/*" }), t, null, "me"), "Repo travis/app");
    assert.strictEqual(F.hiddenReason(config({ filterIncludeRepos: "other/*" }), t, null, "me"), "Repo travis/app");
    assert.strictEqual(F.hiddenReason(config({ filterExcludeTitles: "the thing" }), t, null, "me"), "Title");
    const merged = F.parseThread(raw({ subject: Object.assign(raw().subject, { state: "merged" }) }));
    assert.strictEqual(F.hiddenReason(config({ filterHideMerged: true }), merged, null, "me"), "Merged");
});

test("enrichment filters", () => {
    const t = F.parseThread(raw());
    const e = { author: "renovate-bot", assignees: [], requestedReviewers: ["Me"], labels: ["deps"], draft: true,
                latestCommentAuthor: "ci", latestCommentBody: "ping @someone" };
    assert.strictEqual(F.hiddenReason(config({ filterHideDrafts: true }), t, e, "me"), "Draft");
    assert.strictEqual(F.hiddenReason(config({ filterExcludeAuthors: "*bot" }), t, e, "me"), "Author renovate-bot");
    assert.strictEqual(F.hiddenReason(config({ filterExcludeLabels: "DEPS" }), t, e, "me"), "Label deps");
    assert.strictEqual(F.hiddenReason(config({ filterExcludeCommenters: "ci" }), t, e, "me"), "Comment by ci");
    // Involved as a requested reviewer (case-insensitive).
    assert.strictEqual(F.hiddenReason(config({ filterOnlyInvolved: true }), t, e, "me"), null);
    const uninvolved = Object.assign({}, e, { requestedReviewers: [] });
    assert.strictEqual(F.hiddenReason(config({ filterOnlyInvolved: true }), t, uninvolved, "me"), "Not involved");
    // Unknown (lookup failed) is shown, not hidden.
    assert.strictEqual(F.hiddenReason(config({ filterOnlyInvolved: true }), t, null, "me"), null);
    const commit = F.parseThread(raw({ subject: { type: "Commit", title: "x" } }));
    assert.strictEqual(F.hiddenReason(config({ filterOnlyInvolved: true }), commit, null, "me"), "Not involved");
});

test("mentions", () => {
    assert.ok(F.mentions("hey @Me, look", "me"));
    assert.ok(F.mentions("@me", "me"));
    assert.ok(!F.mentions("hey @mean", "me"));
    assert.ok(!F.mentions("mail me@me.com", "me"));
    assert.ok(!F.mentions("@me-too", "me"));
    assert.ok(F.mentions("thanks @a.b!", "a.b"));
});

test("needs enrichment", () => {
    const t = F.parseThread(raw());
    const f = config({ filterExcludeAuthors: "x" });
    assert.ok(F.needsEnrichment(f, t));
    assert.ok(!F.needsEnrichment(config(), t));
    assert.ok(!F.needsEnrichment(config({ filterExcludeAuthors: "x", filterExcludeRepos: "travis/app" }), t));
    eq(F.staleEnrichments([t], f, { 1: { updatedAt: t.updatedAt, hasComment: false, hasReviewers: false, value: {} } })
        .length, 0);
    eq(F.staleEnrichments([t], f, { 1: { updatedAt: t.updatedAt - 1, hasComment: false, hasReviewers: false, value: {} } })
        .length, 1);
    eq(F.staleEnrichments([t], config({ filterOnlyInvolved: true }),
        { 1: { updatedAt: t.updatedAt, hasComment: true, hasReviewers: false, value: {} } }).length, 1);
});

test("partition", () => {
    const a = F.parseThread(raw({ id: 1, updated_at: "2026-11-21T10:00:00Z" }));
    const b = F.parseThread(raw({ id: 2, updated_at: "2026-11-21T11:00:00Z" }));
    const c = F.parseThread(raw({ id: 3, pinned: true, updated_at: "2026-11-20T11:00:00Z" }));
    const d = F.parseThread(raw({ id: 4, repository: { full_name: "x/y" } }));
    const p = F.partition([a, b, c, d], config({ filterExcludeRepos: "x/*" }), {}, "me");
    eq(p.shown.map(i => i.thread.id), [3, 2, 1]);
    eq(p.hidden.map(i => [i.thread.id, i.reason]), [[4, "Repo x/y"]]);
    eq(F.busiestRepos([a, b, c, d], 1), [{ repo: "travis/app", count: 3 }]);
});

test("tea config", () => {
    const logins = F.parseTeaConfig([
        "logins:",
        "    - name: work",
        "      url: https://git.work",
        "      token: \"abc\"",
        "      default: false",
        "      refresh_token: r",
        "      token_expiry: 1795000000",
        "    - name: home",
        "      url: https://git.home",
        "      default: true",
        "      user: travis",
        "      auth_method: oauth",
        "    - url: https://nameless",
        "preferences:",
        "    editor: false",
    ].join("\n"));
    eq(logins.map(l => l.name), ["work", "home"]);
    assert.strictEqual(logins[0].token, "abc");
    assert.strictEqual(logins[0].isOAuth, true);
    assert.strictEqual(logins[0].tokenExpiry, 1795000000000);
    assert.strictEqual(logins[1].token, "");
    assert.strictEqual(logins[1].isOAuth, true);
    assert.strictEqual(F.pickTeaLogin(logins, "").name, "home");
    assert.strictEqual(F.pickTeaLogin(logins, "work").name, "work");
    assert.strictEqual(F.pickTeaLogin([], ""), null);
    assert.strictEqual(F.parseCredentialHelper("protocol=https\nhost=x\nusername=t\npassword=tok123\n"), "tok123");
    assert.strictEqual(F.parseCredentialHelper("protocol=https\n"), null);
});

test("server and shell", () => {
    assert.strictEqual(F.normalizeServer(" codeberg.org/ "), "https://codeberg.org");
    assert.strictEqual(F.normalizeServer("http://localhost:3000//"), "http://localhost:3000");
    assert.strictEqual(F.normalizeServer(""), null);
    eq(F.hostOf("https://git.example:8443/x"), { protocol: "https", host: "git.example:8443" });
    assert.strictEqual(F.shellQuote("it's"), "'it'\\''s'");
});

test("errors", () => {
    assert.strictEqual(F.errorForStatus(204, ""), null);
    const e = F.errorForStatus(401, '{"message":"token is expired"}');
    eq(F.errorInfo(e), { kind: "unauthorized", title: "Sign-in expired", message: "token is expired", icon: "object-locked" });
    assert.strictEqual(F.errorInfo(F.errorForStatus(502, "<html>")).title, "Server error 502");
    assert.strictEqual(F.errorInfo(F.errorForStatus(0, "")).kind, "network");
});

test("formatting", () => {
    assert.strictEqual(F.ago(now - 30e3, now), "just now");
    assert.strictEqual(F.ago(now - 30e3, now, true), "now");
    assert.strictEqual(F.ago(now - 125e3, now), "2m ago");
    assert.strictEqual(F.ago(now - 5 * 3600e3, now, true), "5h");
    assert.strictEqual(F.ago(now - 3 * 86400e3, now), "3d ago");
    assert.strictEqual(F.ago(Date.parse("2026-09-03T12:00:00"), now), "Sep 3");
    assert.strictEqual(F.countText(120), "99+");
    assert.strictEqual(F.isoSeconds(Date.parse("2026-11-21T12:00:00.789Z")), "2026-11-21T12:00:00Z");
    assert.strictEqual(F.iconFor({ type: "Pull", state: "merged" }), "vcs-merge");
    assert.strictEqual(F.tintFor({ type: "Issue", state: "closed" }), "merged");
    assert.strictEqual(F.tintFor({ type: "Pull", state: "closed" }), "negative");
});

test("paging counts raw entries", () => {
    const page = F.parsePage(JSON.stringify([raw(), raw({ id: 2, updated_at: null })]));
    assert.strictEqual(page.threads.length, 1);
    assert.strictEqual(page.rawCount, 2);
});

test("api URLs stay on the configured origin", () => {
    const base = "https://git.example";
    assert.strictEqual(F.apiURL(base, "notifications"), "https://git.example/api/v1/notifications");
    assert.strictEqual(F.apiURL(base, "https://git.example/api/v1/repos/a/b/issues/1"),
        "https://git.example/api/v1/repos/a/b/issues/1");
    // Misconfigured ROOT_URL: rebased onto the configured server.
    assert.strictEqual(F.apiURL(base, "http://internal:3000/api/v1/repos/a/b/issues/1"),
        "https://git.example/api/v1/repos/a/b/issues/1");
    assert.strictEqual(F.apiURL(base, "https://evil.example/steal"), null);
    // Prefix trick: same string start, different host.
    assert.strictEqual(F.apiURL(base, "https://git.example.evil/x"), null);
});

test("failed lookups", () => {
    const t = F.parseThread(raw());
    const f = config({ filterOnlyInvolved: true });
    const failed = { 1: { updatedAt: t.updatedAt, hasComment: true, hasReviewers: true, value: null, failedAt: now } };
    assert.strictEqual(F.staleEnrichments([t], f, failed, now + 60e3).length, 0);
    assert.strictEqual(F.staleEnrichments([t], f, failed, now + 31 * 60e3).length, 1);
    // Unknown → shown, not "Not involved".
    eq(F.partition([t], f, failed, "me").shown.length, 1);
    const e = { author: "x", assignees: [], requestedReviewers: [], labels: [], commentFailed: true };
    assert.strictEqual(F.hiddenReason(f, t, e, "me"), null);
    assert.strictEqual(F.hiddenReason(f, t, Object.assign({}, e, { commentFailed: false }), "me"), "Not involved");
});

console.log(`${pass} tests passed`);
