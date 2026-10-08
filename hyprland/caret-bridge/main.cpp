// macospills caret-bridge — tiny Hyprland plugin that publishes the
// Wayland text caret to /tmp/macospills-hypr-caret.json for shell.qml.
//
// Why a plugin: the caret rect lives inside the compositor. Every
// well-behaved Wayland client sends it via set_cursor_rectangle over
// text-input-v1/v3, and Hyprland stores it for IME popup placement —
// but nothing exposes it to normal clients (hyprctl has no caret
// command). So we read it in-compositor and publish it.
//
// Probe policy: freshest changed rect among enabled inputs wins, gated
// on input liveness (recent commit/enable, post-title-change) so silent
// blurs hide instead of lingering; trailing disables hide instantly.
// No rendering here — just JSON, so a bug can't take down frames.
//
// Output (atomic tmp+rename, only on change):
//   {"hasCaret":true,"x":123,"y":456,"w":2,"h":20}  (logical px)
//   {"hasCaret":false,"x":0,"y":0,"w":0,"h":0}
// Coords are already compositor logical pixels = the same space
// Quickshell layer-shell uses. No scale math needed.

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/event/EventBus.hpp>
#define private public
#include <hyprland/src/protocols/TextInputV1.hpp>
#include <hyprland/src/protocols/TextInputV3.hpp>
#undef private

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <unordered_map>
#include <vector>
#include <wayland-server-core.h>

namespace {

constexpr const char* STATE_PATH = "/tmp/macospills-hypr-caret.json";
// Transient protocol gaps only (commit/disable races resolve in ms).
// Kept short on purpose: every extra second here is a second of stale
// pill after a blur, while a false-hide self-heals on the next keystroke.
constexpr auto CACHE_TTL = std::chrono::milliseconds(1000);
// How long a disabled-but-last-committed rect stays valid. Covers slow
// typists in clients that never set enabled; a real blur sends disable
// as its last event, which hides instantly regardless of this TTL.
constexpr auto STALE_TTL = std::chrono::seconds(5);
// A rect is only "the caret" while its field is alive: enabled winners
// need a commit or enable within this. Gecko goes silent on
// navigation/close/blur (no commit, no disable), so without this the
// old rect would sit forever. Typing refreshes it constantly; idling
// past the TTL hides until the next keystroke. Short on purpose: a
// false-hide heals on the next keystroke, a false-show just sits wrong.
constexpr auto ACTIVE_TTL = std::chrono::seconds(5);
// A window-title change with no commit near it means navigation, not
// typing side-effects (those land within ~ms of their commit) -> old
// boxes die now. Kept at 150ms, not lower, so slow IPC delivery of a
// title still counts as typing-related. Larger values (500ms) hid real
// Ctrl-Tab switches made shortly after typing: the old tab's fresh box
// stayed alive and won in the new tab.
constexpr auto TITLE_QUIET = std::chrono::milliseconds(150);
// A focus (enable) this fresh outranks box recency: focus just arrived
// here, show this field's last-known caret even if its box is older
// than another field's. Bounds spurious-enable damage to this window.
constexpr auto FOCUS_FRESH = std::chrono::seconds(3);

static HANDLE PHANDLE = nullptr;

// --- tracked inputs (same shape as hyprmac) -------------------------------

struct STrackedV3 {
    WP<CTextInputV3> input;
    uint64_t lastActivity = 0;
    std::chrono::steady_clock::time_point lastSeen{};
    std::chrono::steady_clock::time_point lastCommit{};
    std::chrono::steady_clock::time_point lastDisable{};
    std::chrono::steady_clock::time_point lastEnable{};
    // rect freshness: when the box itself last CHANGED (not just committed)
    CBox lastBox;
    bool hasBox = false;
    std::chrono::steady_clock::time_point boxSeenAt{};
    // surrounding-text identity: Gecko reuses one object across tabs,
    // so an empty box after a text replace is a new tab, not select-all.
    bool hasText = false;
    size_t lastTextHash = 0;
    size_t lastTextLen = 0;
    uint32_t lastCursor = 0;
    uint32_t lastAnchor = 0;
    // text identity when lastBox was recorded
    size_t boxTextHash = 0;
    size_t boxTextLen = 0;
    bool boxTextValid = false;
    // live box contradicted the text this probe (e.g. backspace shrank
    // the text but the rect jumped right): hold lastBox, emit that.
    bool holdBox = false;
    CHyprSignalListener commit, enable, disable, destroy;
};

struct STrackedV1 {
    WP<CTextInputV1> input;
    SP<CWLSurfaceResource> surface;
    uint64_t lastActivity = 0;
    std::chrono::steady_clock::time_point lastSeen{};
    std::chrono::steady_clock::time_point lastCommit{};
    CBox lastBox;
    bool hasBox = false;
    std::chrono::steady_clock::time_point boxSeenAt{};
    CHyprSignalListener commit, enable, disable, destroy;
};

struct SCachedCaret {
    CBox box;
    std::chrono::steady_clock::time_point seenAt;
    size_t textHash = 0;
    size_t textLen = 0;
    bool hasText = false;
};

static size_t textHashOf(const std::string& s) {
    return std::hash<std::string>{}(s);
}

static std::vector<UP<STrackedV3>> g_v3;
static std::vector<UP<STrackedV1>> g_v1;
static uint64_t g_activity = 0;
static std::unordered_map<wl_client*, SCachedCaret> g_cache;
static std::chrono::steady_clock::time_point g_lastGlobalCommit{};
static std::chrono::steady_clock::time_point g_lastTitleChange{};

static CHyprSignalListener s_newV1, s_newV3;
static CHyprSignalListener s_kbFocus, s_winActive, s_wsActive, s_monFocused,
    s_winClose, s_winTitle;
static wl_event_source* s_timer = nullptr;
static uint64_t s_timerCount = 0;

static std::string g_lastJson;
// Focus-generation counter: bumped on window/workspace/monitor/surface
// focus changes so the overlay can re-pop (poke) event-driven instead
// of polling `hyprctl activewindow`.
static uint64_t g_winSeq = 0;
// Last focused-window title: substantial renames mean navigation even
// with a nearby commit (Ctrl-Tab right after typing); tiny mutations
// (dirty `*` markers, counts) are typing churn and ignored.
static std::string g_lastWinTitle;

constexpr const char* LOG_PATH = "/tmp/macospills-caret.log";

static void logPublish(const std::string& js) {
    // Timing-free diagnosis: every published state with a timestamp, so
    // a wrong pill can be traced after the fact (`tail` the log).
    try {
        auto t = std::chrono::system_clock::now();
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      t.time_since_epoch())
                      .count() %
            100000;
        std::string line =
            "[" + std::to_string(ms) + "] " + js + "\n";
        {
            std::ofstream f(LOG_PATH, std::ios::app);
            if (!f.is_open())
                return;
            f << line;
        }
        std::ifstream in(LOG_PATH, std::ios::ate);
        if (in.tellg() > 65536) {
            in.seekg(0);
            std::vector<std::string> lines;
            std::string l;
            while (std::getline(in, l))
                lines.push_back(l);
            std::ofstream f(LOG_PATH, std::ios::trunc);
            size_t from = lines.size() > 100 ? lines.size() - 100 : 0;
            for (size_t i = from; i < lines.size(); ++i)
                f << lines[i] << "\n";
        }
    } catch (...) {
    }
}

static void publish(const std::string& js) {
    if (js == g_lastJson)
        return;
    g_lastJson = js;
    logPublish(js);
    std::string tmp = std::string(STATE_PATH) + ".tmp";
    {
        std::ofstream f(tmp, std::ios::trunc);
        if (!f.is_open())
            return;
        f << js;
    }
    std::rename(tmp.c_str(), STATE_PATH);
}

static void publishNull(const std::string& why, const std::string& app) {
    char buf[384];
    std::snprintf(buf, sizeof(buf),
                  "{\"hasCaret\":false,\"x\":0,\"y\":0,\"w\":0,\"h\":0,"
                  "\"why\":\"%s\",\"app\":\"%s\",\"win\":%llu}",
                  why.c_str(), app.c_str(),
                  (unsigned long long)g_winSeq);
    publish(buf);
}

static void publishCaret(int x, int y, int w, int h, const std::string& why,
                         const std::string& app) {
    char buf[384];
    std::snprintf(buf, sizeof(buf),
                  "{\"hasCaret\":true,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,"
                  "\"why\":\"%s\",\"app\":\"%s\",\"win\":%llu}",
                  x, y, w, h, why.c_str(), app.c_str(),
                  (unsigned long long)g_winSeq);
    publish(buf);
}

// Rough edit size between two window titles (common prefix+suffix
// trimmed). Typing churn mutates a couple of chars; navigation renames.
static size_t titleEditSize(const std::string& a, const std::string& b) {
    if (a == b)
        return 0;
    size_t pre = 0;
    while (pre < a.size() && pre < b.size() && a[pre] == b[pre])
        ++pre;
    size_t suf = 0;
    while (suf < a.size() - pre && suf < b.size() - pre &&
           a[a.size() - 1 - suf] == b[b.size() - 1 - suf])
        ++suf;
    return (a.size() - pre - suf) + (b.size() - pre - suf);
}

static std::string focusApp() {
    try {
        auto w = Desktop::focusState()->window();
        if (w)
            return std::string(w->m_class);
    } catch (...) {
    }
    return "";
}

// --- probe ----------------------------------------------------------------

static std::optional<CBox> surfaceBoxGlobal(const SP<CWLSurfaceResource>& surf) {
    if (!surf)
        return std::nullopt;
    auto hl = Desktop::View::CWLSurface::fromResource(surf);
    if (!hl)
        return std::nullopt;
    return hl->getSurfaceBoxGlobal();
}

static void probeAndPublish() {
    auto focusSurface = Desktop::focusState()->surface();
    const std::string app = focusApp();
    if (!focusSurface) {
        publishNull("no_focus_surface", app);
        return;
    }
    // Hidden window (minimized, on an inactive workspace, closing):
    // its caret is invisible — never point at it.
    try {
        auto w = Desktop::focusState()->window();
        if (w && w->isHidden()) {
            publishNull("window_hidden", app);
            return;
        }
    } catch (...) {
    }
    auto sbox = surfaceBoxGlobal(focusSurface);
    if (!sbox) {
        publishNull("no_surface_box", app);
        return;
    }

    // Live relay snapshot (compositor-blessed focus, queried now — not
    // stale). Lets an idle-but-still-focused caret survive ACTIVE_TTL:
    // a held pill must not vanish while reading. Silent blurs clear the
    // relay, so those still hide.
    CBox relayBox{};
    bool relayOk = false;
    try {
        if (auto* relay = g_pInputManager->m_relay.getFocusedTextInput()) {
            if (relay->focusedSurface() == focusSurface &&
                relay->isEnabled() && relay->hasCursorRectangle()) {
                CBox c = relay->cursorBox();
                if (c.w > 0 || c.h > 0) {
                    relayBox = c;
                    relayOk = true;
                }
            }
        }
    } catch (...) {
        relayOk = false;
    }

    // Policy: freshest RECT wins among enabled direct inputs. Commit
    // recency alone lied: an enable/commit can arrive for a field switch
    // while m_current still holds the previous field's box, so ordering
    // by commit activity re-published stale rects at "random" spots.
    // Ordering by when the box itself last changed tracks the real caret:
    // keystrokes (incl. backspace) and field/tab switches that move the
    // caret always change the box; a vacated field's box goes quiet.
    // Disabled-but-updated rects are trusted only while the last event
    // was a commit (actively typing) and recent: a trailing disable
    // means the field was vacated -> hide immediately.
    // Liveness: Gecko goes silent on navigation/close/blur (no commit,
    // no disable), so an enabled rect is only "the caret" while its
    // field had input activity recently AND after the last window-title
    // change (navigation without nearby commits). Typing refreshes
    // constantly; idling past the TTL hides until the next keystroke.
    const auto now = std::chrono::steady_clock::now();
    auto sameBox = [](const CBox& a, const CBox& b) {
        return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
    };
    auto boxesClose = [](const CBox& a, const CBox& b) {
        return std::fabs(a.x - b.x) + std::fabs(a.y - b.y) <= 8;
    };
    auto alive = [&](std::chrono::steady_clock::time_point commit,
                     std::chrono::steady_clock::time_point enable) {
        auto last = std::max(commit, enable);
        return last >= g_lastTitleChange && now - last <= ACTIVE_TTL;
    };

    CTextInputV3* bestV3 = nullptr;
    STrackedV3* bestV3T = nullptr;
    std::chrono::steady_clock::time_point bestV3Box{};
    uint64_t actV3 = 0;
    // Focus-fresh winner: most recently ENABLED box-holder. A fresh
    // enable means "focus just arrived here" even if the box hasn't
    // re-committed (e.g. back to a tab whose caret never moved) — it
    // outranks a fresher box on a blurred field. Only while fresh;
    // ancient enables mean nothing (clients that never disable) and
    // fall back to box ordering below.
    CTextInputV3* focusV3 = nullptr;
    STrackedV3* focusV3T = nullptr;
    std::chrono::steady_clock::time_point focusV3Box{};
    uint64_t focusActV3 = 0;
    CTextInputV3* staleV3 = nullptr; // enabled=no but still committing
    STrackedV3* staleV3T = nullptr;
    std::chrono::steady_clock::time_point staleV3Box{};
    uint64_t staleActV3 = 0;
    STrackedV3* emptyT = nullptr; // enabled + empty box (e.g. select-all)
    uint64_t emptyActV3 = 0;
    int sameClientV3 = 0, updatedV3 = 0, enabledV3 = 0, disabledV3 = 0,
        emptyV3 = 0;
    // Per-client input vitality: the freshest commit/enable among this
    // client's objects. Gates the relay below (which carries no
    // timestamps of its own).
    auto clientMark = std::chrono::steady_clock::time_point{};
    // Surrounding-text identity for this client this probe: Gecko reuses
    // one text-input object across tabs, so a text replace without a
    // fresh box means the field changed (Ctrl-T), not typing.
    bool clientHasText = false;
    size_t clientTextHash = 0;
    size_t clientTextLen = 0;
    uint64_t clientTextAct = 0;
    bool textSwitchedWithoutBox = false;
    bool anyBoxUpdatedNow = false;
    for (auto& t : g_v3) {
        auto in = t->input.lock();
        if (!in || in->client() != focusSurface->client())
            continue;
        sameClientV3++;
        clientMark = std::max({clientMark, t->lastCommit, t->lastEnable});
        // Track surrounding text before looking at the box. m_current
        // keeps the last committed values, so compare content: a hash/len
        // change means new text even when the box didn't re-commit.
        size_t curHash = 0;
        size_t curLen = 0;
        uint32_t curCursor = 0;
        uint32_t curAnchor = 0;
        bool surKnown = false;
        try {
            const auto& sur = in->m_current.surrounding;
            if (sur.updated) {
                curLen = sur.text.size();
                curHash = textHashOf(sur.text);
                curCursor = sur.cursor;
                curAnchor = sur.anchor;
                surKnown = true;
            }
        } catch (...) {
            surKnown = false;
        }
        if (surKnown) {
            if (!t->hasText) {
                t->hasText = true;
                t->lastTextHash = curHash;
                t->lastTextLen = curLen;
                t->lastCursor = curCursor;
                t->lastAnchor = curAnchor;
            } else if (curHash != t->lastTextHash ||
                       curLen != t->lastTextLen) {
                // Text replaced (tab switch, field clear). Typing also
                // changes text, but typing always ships a fresh
                // non-empty box alongside — handled below.
                bool boxFresh = in->m_current.box.updated &&
                    (in->m_current.box.cursorBox.w > 0 ||
                     in->m_current.box.cursorBox.h > 0);
                t->lastTextHash = curHash;
                t->lastTextLen = curLen;
                t->lastCursor = curCursor;
                t->lastAnchor = curAnchor;
                if (t->lastActivity >= clientTextAct) {
                    clientHasText = true;
                    clientTextHash = curHash;
                    clientTextLen = curLen;
                    clientTextAct = t->lastActivity;
                }
                if (!boxFresh) {
                    // New text, no caret for it yet (e.g. Ctrl-T to an
                    // empty bar reusing the same object): drop the old
                    // box now instead of holding it until typing.
                    t->hasBox = false;
                    textSwitchedWithoutBox = true;
                    continue;
                }
                // else: text+box changed together = steady typing,
                // fall through to the normal box update.
            } else {
                t->lastCursor = curCursor;
                t->lastAnchor = curAnchor;
            }
            if (t->lastActivity >= clientTextAct) {
                clientHasText = true;
                clientTextHash = curHash;
                clientTextLen = curLen;
                clientTextAct = t->lastActivity;
            }
        }
        if (!in->m_current.box.updated)
            continue;
        auto c = in->m_current.box.cursorBox;
        // Fully empty box: degenerate, with one exception — enabled +
        // empty (e.g. select-all collapses the caret) holds the last
        // published pos while its commits keep flowing, instead of
        // vanishing. A trailing disable still hides instantly.
        // Zero-width but tall is a real caret line in an empty field.
        bool empty = (c.w <= 0 && c.h <= 0);
        if (!empty) {
            updatedV3++;
            if (!t->hasBox || !sameBox(c, t->lastBox)) {
                // Single-line directional sanity: on a staggered
                // text+box pair the live rect must agree with the length
                // delta (shrink => not right, grow => not left). A
                // contradicting commit (Zen backspace transient) holds
                // the old box for this probe instead of jumping wrong.
                bool contradict = false;
                if (t->hasBox && t->hasText && surKnown && t->boxTextValid &&
                    c.y == t->lastBox.y) {
                    if (curLen < t->boxTextLen && c.x > t->lastBox.x + 2)
                        contradict = true;
                    else if (curLen > t->boxTextLen && c.x + 2 < t->lastBox.x)
                        contradict = true;
                }
                if (contradict) {
                    t->holdBox = true;
                } else {
                    t->lastBox = c;
                    t->hasBox = true;
                    t->holdBox = false;
                    t->boxSeenAt = now;
                    anyBoxUpdatedNow = true;
                    if (t->hasText) {
                        t->boxTextHash = t->lastTextHash;
                        t->boxTextLen = t->lastTextLen;
                        t->boxTextValid = true;
                    }
                }
            } else {
                t->holdBox = false;
                if (t->hasText && surKnown) {
                    // staggered text-follow commit: same caret, new text —
                    // rebind so the next delta compares to fresh text.
                    t->boxTextHash = curHash;
                    t->boxTextLen = curLen;
                    t->boxTextValid = true;
                } else if (t->hasText && !t->boxTextValid) {
                    // box predates text tracking: bind it to current text
                    // so a later empty-after-replace can tell them apart.
                    t->boxTextHash = t->lastTextHash;
                    t->boxTextLen = t->lastTextLen;
                    t->boxTextValid = true;
                }
            }
        }
        auto fresher = [&](auto otherBox, auto otherAct) {
            return t->boxSeenAt > otherBox ||
                (t->boxSeenAt == otherBox && t->lastActivity >= otherAct);
        };
        if (in->m_current.enabled.value) {
            enabledV3++;
            if (empty) {
                emptyV3++;
                // Empty after a text replace was already handled above
                // (invalidated + textSwitchedWithoutBox). What remains
                // here is a genuinely collapsed caret: only hold it when
                // the text is unchanged and there is a selection
                // (Ctrl-A collapse). A steady empty field (no selection)
                // must hide, not hold the old pos.
                if (t->hasText && t->lastCursor == t->lastAnchor)
                    continue;
                if (t->lastCommit > t->lastDisable &&
                    now - t->lastCommit <= STALE_TTL &&
                    (!emptyT || t->lastActivity >= emptyActV3)) {
                    emptyT = t.get();
                    emptyActV3 = t->lastActivity;
                }
                continue;
            }
            if (!bestV3 || fresher(bestV3Box, actV3)) {
                bestV3 = in.get();
                bestV3T = t.get();
                bestV3Box = t->boxSeenAt;
                actV3 = t->lastActivity;
            }
            if (!focusV3 || t->lastEnable > focusV3T->lastEnable ||
                (t->lastEnable == focusV3T->lastEnable &&
                 fresher(focusV3Box, focusActV3))) {
                focusV3 = in.get();
                focusV3T = t.get();
                focusV3Box = t->boxSeenAt;
                focusActV3 = t->lastActivity;
            }
        } else {
            if (empty)
                continue;
            disabledV3++;
            // last event commit (not disable) + recent = still typing
            // in a client that never sets enabled; a trailing disable
            // means vacated -> hide now.
            if (t->lastCommit > t->lastDisable &&
                now - t->lastCommit <= STALE_TTL &&
                (!staleV3 || fresher(staleV3Box, staleActV3))) {
                staleV3 = in.get();
                staleV3T = t.get();
                staleV3Box = t->boxSeenAt;
                staleActV3 = t->lastActivity;
            }
        }
    }

    CTextInputV1* bestV1 = nullptr;
    STrackedV1* bestV1T = nullptr;
    std::chrono::steady_clock::time_point bestV1Box{};
    uint64_t actV1 = 0;
    int sameSurfV1 = 0, rectV1 = 0;
    for (auto& t : g_v1) {
        auto in = t->input.lock();
        if (!in || !in->m_active || t->surface != focusSurface)
            continue;
        sameSurfV1++;
        clientMark = std::max(clientMark, t->lastCommit);
        auto r = in->m_cursorRectangle;
        if (r.w <= 0 && r.h <= 0)
            continue;
        rectV1++;
        if (!t->hasBox || !sameBox(r, t->lastBox)) {
            t->lastBox = r;
            t->hasBox = true;
            t->boxSeenAt = now;
        }
        if (!bestV1 || t->boxSeenAt > bestV1Box ||
            (t->boxSeenAt == bestV1Box && t->lastActivity >= actV1)) {
            bestV1 = in.get();
            bestV1T = t.get();
            bestV1Box = t->boxSeenAt;
            actV1 = t->lastActivity;
        }
    }

    auto emitBox = [&](const CBox& c, const std::string& why) {
        SCachedCaret cc;
        cc.box = c;
        cc.seenAt = now;
        cc.hasText = clientHasText;
        cc.textHash = clientTextHash;
        cc.textLen = clientTextLen;
        g_cache[focusSurface->client()] = cc;
        publishCaret((int)std::round(sbox->x + c.x),
                     (int)std::round(sbox->y + c.y),
                     (int)std::round(c.w <= 0 ? 2 : c.w),
                     (int)std::round(c.h <= 0 ? 20 : c.h), why, app);
    };

    // Same-object tab switch (Gecko reuses the URL-bar input): the text
    // was replaced but no caret arrived for the new text. Hiding now is
    // correct; holding the old tab's box is the reported bug. Exception:
    // a box updated in this very probe alongside the text = steady
    // typing, let it win below.
    if (textSwitchedWithoutBox && !anyBoxUpdatedNow) {
        publishNull("field-switch-text", app);
        return;
    }

    // 1. enabled direct winner. Fresh focus outranks fresh box: an
    // enable within FOCUS_FRESH means "focus just arrived here" even if
    // the box hasn't re-committed (back to a tab whose caret never
    // moved). Otherwise the freshest changed box wins (steady typing).
    // Either way gated on liveness: the field must have had input
    // activity since the last title change and within ACTIVE_TTL, or
    // the rect is from a field Gecko silently abandoned
    // (navigation/close/blur send nothing) and must hide instead.
    CTextInputV3* winV3 = nullptr;
    STrackedV3* winV3T = nullptr;
    std::chrono::steady_clock::time_point winV3Box{};
    uint64_t winActV3 = 0;
    const char* winWhy = "direct-v3";
    // Focus-fresh winner must also be text-consistent: if its box was
    // recorded for older text (tab navigated, same object reused), the
    // box is stale even though the enable is fresh. Fall back to box
    // recency / hide instead of showing the opposite tab's pos.
    bool focusValid = false;
    if (focusV3 && now - focusV3T->lastEnable <= FOCUS_FRESH) {
        focusValid = true;
        if (focusV3T->hasText && focusV3T->hasBox && focusV3T->boxTextValid &&
            (focusV3T->boxTextHash != focusV3T->lastTextHash ||
             focusV3T->boxTextLen != focusV3T->lastTextLen))
            focusValid = false;
        if (!focusV3T->hasBox)
            focusValid = false;
    }
    if (focusValid) {
        winV3 = focusV3;
        winV3T = focusV3T;
        winV3Box = focusV3Box;
        winActV3 = focusActV3;
        winWhy = "direct-v3-focus";
    } else if (bestV3) {
        winV3 = bestV3;
        winV3T = bestV3T;
        winV3Box = bestV3Box;
        winActV3 = actV3;
    }
    bool v3Wins = winV3 && (!bestV1 || winV3Box > bestV1Box ||
                            (winV3Box == bestV1Box && winActV3 >= actV1));
    bool timeAlive = v3Wins && alive(winV3T->lastCommit, winV3T->lastEnable);
    // Idle hold: past ACTIVE_TTL but the relay still reports the same
    // rect right now on this surface, with no trailing disable and no
    // navigation since the last commit. Reading, not blurred.
    bool relayConfirm = false;
    if (v3Wins && !timeAlive && relayOk &&
        winV3T->lastCommit >= g_lastTitleChange &&
        !(winV3T->lastDisable > winV3T->lastCommit))
        relayConfirm = boxesClose(winV3->m_current.box.cursorBox, relayBox);
    if (v3Wins && (timeAlive || relayConfirm)) {
        // field-switch guard: a DIFFERENT same-client object was enabled
        // strictly after the winner's box last changed -> focus moved to
        // a field that hasn't committed a box yet; hide instead of showing
        // the vacated field's stale rect. First box commit there wins.
        for (auto& t : g_v3) {
            auto in = t->input.lock();
            if (!in || in.get() == winV3)
                continue;
            if (in->client() != focusSurface->client())
                continue;
            auto winRef = std::max(winV3Box, winV3T->lastEnable);
            if (t->lastEnable > winRef + std::chrono::milliseconds(500)) {
                publishNull("field-switch", app);
                return;
            }
        }
        if (winV3T->holdBox && winV3T->hasBox) {
            emitBox(winV3T->lastBox, "held-transient");
            return;
        }
        emitBox(winV3->m_current.box.cursorBox,
                timeAlive ? winWhy : "direct-v3-idle");
        return;
    }
    if (bestV1 && alive(bestV1T->lastCommit, bestV1T->lastSeen)) {
        emitBox(bestV1->m_cursorRectangle, "direct-v1");
        return;
    }
    // 1b. disabled but actively committing (sloppy enable, still typing)
    if (staleV3 && staleV3T->lastCommit >= g_lastTitleChange) {
        emitBox(staleV3->m_current.box.cursorBox, "direct-v3-stale");
        return;
    }
    // 1c. enabled but empty box (select-all hold): hold this field's
    // OWN last box, not the client cache (which may hold another
    // field's pos — e.g. a brand-new empty tab must hide, not show the
    // old tab's caret). Holds while its commits keep flowing, and only
    // while the text still matches the text the box was seen with
    // (tab clear changes text -> hide, handled above).
    if (emptyT && emptyT->lastCommit >= g_lastTitleChange &&
        emptyT->hasBox) {
        if (emptyT->hasText && emptyT->boxTextValid &&
            (emptyT->lastTextHash != emptyT->boxTextHash ||
             emptyT->lastTextLen != emptyT->boxTextLen)) {
            publishNull("empty-tab-hide", app);
            return;
        }
        emitBox(emptyT->lastBox, "selection-hold");
        return;
    }

    // 2. relay (compositor-blessed focus; covers objects we missed),
    // gated on client vitality: the relay carries no timestamps, and an
    // ungated stale relay reintroduces forever-stuck through the back
    // door. Only served while this client had input activity recently
    // and after the last title change.
    bool clientAlive = clientMark >= g_lastTitleChange &&
        now - clientMark <= ACTIVE_TTL;
    if (clientAlive && relayOk) {
        emitBox(relayBox, "relay");
        return;
    }

    // 4. short same-client cache (covers transient protocol gaps) —
    // but never across a trailing disable: a disable newer than the
    // cached caret means the field was vacated after we published it,
    // so hide now instead of lingering on the cache. The disable
    // listener already re-probes synchronously, making hides instant.
    // Also never across a text replace: the cached box belongs to the
    // old text (old tab), not the current one.
    {
        auto it = g_cache.find(focusSurface->client());
        if (it != g_cache.end() &&
            std::chrono::steady_clock::now() - it->second.seenAt <= CACHE_TTL) {
            bool vacated = false;
            for (auto& t : g_v3) {
                auto in = t->input.lock();
                if (!in || in->client() != focusSurface->client())
                    continue;
                if (t->lastDisable > it->second.seenAt &&
                    t->lastDisable >= t->lastCommit) {
                    vacated = true;
                    break;
                }
            }
            bool textMismatch = false;
            if (!vacated && it->second.hasText && clientHasText &&
                (it->second.textHash != clientTextHash ||
                 it->second.textLen != clientTextLen))
                textMismatch = true;
            if (textSwitchedWithoutBox)
                textMismatch = true;
            if (!vacated && !textMismatch) {
                auto c = it->second.box;
                publishCaret((int)std::round(sbox->x + c.x),
                             (int)std::round(sbox->y + c.y),
                             (int)std::round(c.w <= 0 ? 2 : c.w),
                             (int)std::round(c.h <= 0 ? 20 : c.h), "cached", app);
                return;
            }
        }
    }

    // include tracked-object counts so `cat` tells us if the app even
    // speaks text-input (cli=0 => client binds nothing => hidden pill is
    // correct, not a bug; dis>0 with no enabled => field vacated)
    char detail[160];
    std::snprintf(detail, sizeof(detail),
                  "no_caret v3=%zu cli=%d upd=%d en=%d dis=%d empty=%d v1surf=%d",
                  g_v3.size(), sameClientV3, updatedV3, enabledV3,
                  disabledV3, emptyV3, sameSurfV1);
    publishNull(detail, app);
}

static void touchV3(STrackedV3* t) {
    if (t) {
        t->lastActivity = ++g_activity;
        t->lastSeen = std::chrono::steady_clock::now();
    }
}
static void touchV1(STrackedV1* t) {
    if (t) {
        t->lastActivity = ++g_activity;
        t->lastSeen = std::chrono::steady_clock::now();
    }
}

static void registerV3(WP<CTextInputV3> weak) {
    auto in = weak.lock();
    if (!in)
        return;
    for (auto& t : g_v3)
        if (t->input.lock() == in)
            return;
    auto t = makeUnique<STrackedV3>();
    auto* raw = t.get();
    raw->input = weak;
    touchV3(raw);
    raw->commit = in->m_events.onCommit.listen([raw] {
        touchV3(raw);
        raw->lastCommit = std::chrono::steady_clock::now();
        g_lastGlobalCommit = raw->lastCommit;
        probeAndPublish();
    });
    raw->enable = in->m_events.enable.listen([raw] {
        touchV3(raw);
        raw->lastEnable = std::chrono::steady_clock::now();
        probeAndPublish();
    });
    raw->disable = in->m_events.disable.listen([raw] {
        touchV3(raw);
        raw->lastDisable = std::chrono::steady_clock::now();
        probeAndPublish();
    });
    raw->destroy = in->m_events.destroy.listen([raw] {
        probeAndPublish();
        std::erase_if(g_v3, [raw](auto& o) { return o.get() == raw; });
    });
    g_v3.emplace_back(std::move(t));
}

static void registerV1(WP<CTextInputV1> weak) {
    auto in = weak.lock();
    if (!in)
        return;
    for (auto& t : g_v1)
        if (t->input.lock() == in)
            return;
    auto t = makeUnique<STrackedV1>();
    auto* raw = t.get();
    raw->input = weak;
    touchV1(raw);
    raw->commit = in->m_events.onCommit.listen([raw] {
        touchV1(raw);
        raw->lastCommit = std::chrono::steady_clock::now();
        g_lastGlobalCommit = raw->lastCommit;
        probeAndPublish();
    });
    raw->enable = in->m_events.enable.listen([raw](SP<CWLSurfaceResource> s) {
        raw->surface = s;
        touchV1(raw);
        probeAndPublish();
    });
    raw->disable = in->m_events.disable.listen([raw] {
        raw->surface.reset();
        touchV1(raw);
        probeAndPublish();
    });
    raw->destroy = in->m_events.destroy.listen([raw] {
        probeAndPublish();
        std::erase_if(g_v1, [raw](auto& o) { return o.get() == raw; });
    });
    if (in->m_active)
        raw->surface = Desktop::focusState()->surface();
    g_v1.emplace_back(std::move(t));
}

// --- debug table (hyprctl macospills:inputs) --------------------------------

static std::string dumpInputs(eHyprCtlOutputFormat, std::string) {
    const auto now = std::chrono::steady_clock::now();
    auto ageMs = [&](std::chrono::steady_clock::time_point t) -> long {
        if (t == std::chrono::steady_clock::time_point{})
            return -1;
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   now - t)
            .count();
    };
    std::string out;
    out += "focus app=" + focusApp() + "\n";
    out += "timerTicks=" + std::to_string(s_timerCount) + "\n";
    auto focusClient = Desktop::focusState()->surface() ?
        Desktop::focusState()->surface()->client() : nullptr;
    char line[320];
    for (auto& t : g_v3) {
        auto in = t->input.lock();
        if (!in)
            continue;
        const auto& st = in->m_current;
        const auto& c = st.box.cursorBox;
        std::snprintf(line, sizeof(line),
                      "%cv3 client=%p en=%d upd=%d box=(%.0f,%.0f %.0fx%.0f) "
                      "actAge=%ldms boxAge=%ldms commitAge=%ldms disAge=%ldms "
                      "txtLen=%zu cur=%u anch=%u surUpd=%d\n",
                      (focusClient && in->client() == focusClient) ? '>' : ' ',
                      (void*)in->client(), (int)st.enabled.value,
                      (int)st.box.updated, c.x, c.y, c.w, c.h,
                      ageMs(t->lastSeen), ageMs(t->boxSeenAt),
                      ageMs(t->lastCommit), ageMs(t->lastDisable),
                      st.surrounding.text.size(), (unsigned)st.surrounding.cursor,
                      (unsigned)st.surrounding.anchor, (int)st.surrounding.updated);
        out += line;
    }
    for (auto& t : g_v1) {
        auto in = t->input.lock();
        if (!in)
            continue;
        const auto& r = in->m_cursorRectangle;
        std::snprintf(line, sizeof(line),
                      "v1 active=%d box=(%.0f,%.0f %.0fx%.0f) "
                      "actAge=%ldms boxAge=%ldms sameSurf=%d\n",
                      (int)in->m_active, r.x, r.y, r.w, r.h,
                      ageMs(t->lastSeen), ageMs(t->boxSeenAt),
                      (int)(t->surface == Desktop::focusState()->surface()));
        out += line;
    }
    return out;
}

static SP<SHyprCtlCommand> s_inputsCmd;

static int onTimerTick(void*) {
    s_timerCount++;
    probeAndPublish();
    if (s_timer)
        wl_event_source_timer_update(s_timer, 500);
    return 0;
}

} // namespace

// --- plugin entry points --------------------------------------------------

APICALL EXPORT std::string pluginAPIVersion() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO pluginInit(HANDLE handle) {
    PHANDLE = handle;

    // version guard (same approach as hyprmac: compare our client hash)
    {
        auto info = HyprlandAPI::getHyprlandVersion(handle);
        (void)info;
    }

    if (PROTO::textInputV1) {
        for (auto& in : PROTO::textInputV1->m_clients)
            registerV1(in);
        s_newV1 = PROTO::textInputV1->m_events.newTextInput.listen(
            [](WP<CTextInputV1> in) { registerV1(in); });
    }
    if (PROTO::textInputV3) {
        for (auto& in : PROTO::textInputV3->m_textInputs)
            registerV3(in);
        s_newV3 = PROTO::textInputV3->m_events.newTextInput.listen(
            [](WP<CTextInputV3> in) { registerV3(in); });
    }

    s_kbFocus = Event::bus()->m_events.input.keyboard.focus.listen(
        [](SP<CWLSurfaceResource>) {
            ++g_winSeq;
            probeAndPublish();
        });
    s_winActive = Event::bus()->m_events.window.active.listen(
        [](PHLWINDOW, Desktop::eFocusReason) {
            ++g_winSeq;
            probeAndPublish();
        });
    // Focus can move without any text-input/keyboard event (workspace
    // switch to an empty workspace, window close/minimize leaving no
    // focus): re-probe on those too, or the old rect lingers instead of
    // hiding.
    s_wsActive = Event::bus()->m_events.workspace.active.listen(
        [](PHLWORKSPACE) {
            ++g_winSeq;
            probeAndPublish();
        });
    s_monFocused = Event::bus()->m_events.monitor.focused.listen(
        [](PHLMONITOR) {
            ++g_winSeq;
            probeAndPublish();
        });
    s_winClose = Event::bus()->m_events.window.close.listen(
        [](PHLWINDOW) { probeAndPublish(); });
    // Title change: substantial renames mean navigation even with a
    // nearby commit (Ctrl-Tab right after typing); tiny mutations are
    // typing churn and only count when isolated (no commit near them).
    // Typing side-effects land within ~ms of their commit.
    s_winTitle = Event::bus()->m_events.window.title.listen(
        [](PHLWINDOW w) {
            auto now = std::chrono::steady_clock::now();
            std::string t;
            try {
                t = w ? w->m_title : "";
            } catch (...) {
                t = "";
            }
            bool nav = titleEditSize(g_lastWinTitle, t) > 3;
            g_lastWinTitle = t;
            if (nav || now - g_lastGlobalCommit > TITLE_QUIET)
                g_lastTitleChange = now;
            probeAndPublish();
        });
    // Periodic backstop: TTLs only expire when a probe runs, and some
    // focus losses (ESC-blur to page body, silent tab switches) emit no
    // observable event at all. A wall-clock timer on the compositor loop
    // re-probes 1/s so time-based expiry actually fires. (The bus `tick`
    // event never fires in this build, hence the explicit timer.)
    if (g_pCompositor && g_pCompositor->m_wlEventLoop) {
        s_timer = wl_event_loop_add_timer(g_pCompositor->m_wlEventLoop,
                                          onTimerTick, nullptr);
        if (s_timer)
            wl_event_source_timer_update(s_timer, 500);
    }

    s_inputsCmd = HyprlandAPI::registerHyprCtlCommand(
        handle, SHyprCtlCommand{
                    .name = "macospills:inputs",
                    .exact = true,
                    .fn = [](eHyprCtlOutputFormat f, std::string a) {
                        return dumpInputs(f, std::move(a));
                    },
                });

    // Statics survive dlclose/dlopen: force a fresh publish so the state
    // file exists right after (re)load instead of waiting for the next
    // caret change (QML FileView warns until then).
    g_lastJson.clear();
    g_lastGlobalCommit = std::chrono::steady_clock::time_point{};
    g_lastTitleChange = std::chrono::steady_clock::time_point{};
    try {
        if (auto w = Desktop::focusState()->window())
            g_lastWinTitle = w->m_title;
    } catch (...) {
    }
    probeAndPublish();

    HyprlandAPI::addNotification(handle, "[macospills] caret-bridge loaded",
                                 CHyprColor{0.2, 0.8, 0.2, 1.0}, 2500);
    return {"macospills-caret-bridge",
            "Publishes Wayland text caret to /tmp for the caps pill",
            "macospills", "0.1.0"};
}

APICALL EXPORT void pluginExit() {
    if (s_inputsCmd) {
        HyprlandAPI::unregisterHyprCtlCommand(PHANDLE, s_inputsCmd);
        s_inputsCmd.reset();
    }
    s_newV1.reset();
    s_newV3.reset();
    s_kbFocus.reset();
    s_winActive.reset();
    s_wsActive.reset();
    s_monFocused.reset();
    s_winClose.reset();
    s_winTitle.reset();
    if (s_timer) {
        wl_event_source_remove(s_timer);
        s_timer = nullptr;
    }
    g_v1.clear();
    g_v3.clear();
    g_cache.clear();
    std::remove(STATE_PATH);
}
