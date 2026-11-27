(function () {
  "use strict";

  var REPO_URL = "https://github.com/dasimmet/ssh-copy-id";
  var PAGES_URL = "https://dasimmet.github.io/ssh-copy-id";

  var state = {
    tab: "unix",
    suggestedTab: "unix",
    channel: "latest",
    scope: "user",
    detected: {
      os: "unknown",
      osLabel: "Unknown OS",
      arch: "unknown",
      target: null,
      archiveExt: "tar.gz"
    }
  };

  function detectSyncPlatform() {
    var ua = (navigator.userAgent || "").toLowerCase();
    var plat = (navigator.platform || "").toLowerCase();

    var os = "unknown";
    var osLabel = "Unix / POSIX";
    var archiveExt = "tar.gz";

    if (ua.indexOf("windows") !== -1 || plat.indexOf("win") !== -1) {
      os = "windows";
      osLabel = "Windows";
      archiveExt = "zip";
    } else if (ua.indexOf("mac os") !== -1 || ua.indexOf("macintosh") !== -1 || plat.indexOf("mac") !== -1) {
      os = "macos";
      osLabel = "macOS";
    } else if (ua.indexOf("freebsd") !== -1 || plat.indexOf("freebsd") !== -1) {
      os = "freebsd";
      osLabel = "FreeBSD";
    } else if (ua.indexOf("openbsd") !== -1 || plat.indexOf("openbsd") !== -1) {
      os = "openbsd";
      osLabel = "OpenBSD";
    } else if (ua.indexOf("netbsd") !== -1 || plat.indexOf("netbsd") !== -1) {
      os = "netbsd";
      osLabel = "NetBSD";
    } else if (ua.indexOf("linux") !== -1 || plat.indexOf("linux") !== -1) {
      os = "linux";
      osLabel = "Linux";
    }

    var arch = "unknown";
    if (/aarch64|arm64/.test(ua) || /aarch64|arm64/.test(plat)) {
      arch = "aarch64";
    } else if (/armv7|armv8l|armhf/.test(ua) || /armv7/.test(plat)) {
      arch = "arm";
    } else if (/riscv64/.test(ua) || /riscv64/.test(plat)) {
      arch = "riscv64";
    } else if (/loongarch64/.test(ua) || /loongarch64/.test(plat)) {
      arch = "loongarch64";
    } else if (/x86_64|x86-64|win64|wow64|amd64|x64/.test(ua) || /x86_64|amd64/.test(plat)) {
      arch = "x86_64";
    } else if (os === "windows" && !/win64|wow64|x64|arm64/.test(ua)) {
      arch = "x86";
    }

    return buildDetection(os, osLabel, arch, archiveExt);
  }

  function buildDetection(os, osLabel, arch, archiveExt) {
    var target = null;
    if (os === "linux") {
      if (arch === "x86_64" || arch === "aarch64" || arch === "riscv64" || arch === "loongarch64") {
        target = arch + "-linux-musl";
      } else if (arch === "arm") {
        target = "arm-linux-musleabihf";
      } else if (arch === "x86") {
        target = "x86-linux-musl";
      }
    } else if (os === "macos" || os === "freebsd" || os === "openbsd" || os === "netbsd") {
      if (arch === "x86_64" || arch === "aarch64") {
        target = arch + "-" + os;
      }
    } else if (os === "windows") {
      if (arch === "x86_64" || arch === "aarch64" || arch === "x86") {
        target = arch + "-windows";
      }
    }
    return {
      os: os,
      osLabel: osLabel,
      arch: arch,
      target: target,
      archiveExt: archiveExt
    };
  }

  async function detectPlatformAsync() {
    var base = detectSyncPlatform();
    if (!navigator.userAgentData || !navigator.userAgentData.getHighEntropyValues) {
      return base;
    }
    try {
      var hints = await navigator.userAgentData.getHighEntropyValues(["platform", "architecture", "bitness"]);
      var p = (hints.platform || navigator.userAgentData.platform || "").toLowerCase();
      var os = base.os;
      var osLabel = base.osLabel;
      var archiveExt = base.archiveExt;

      if (p === "windows") {
        os = "windows";
        osLabel = "Windows";
        archiveExt = "zip";
      } else if (p === "macos") {
        os = "macos";
        osLabel = "macOS";
        archiveExt = "tar.gz";
      } else if (p === "linux") {
        os = "linux";
        osLabel = "Linux";
        archiveExt = "tar.gz";
      }

      var a = (hints.architecture || "").toLowerCase();
      var bits = hints.bitness || "";
      var arch = base.arch;
      if (a === "arm") {
        arch = bits === "64" ? "aarch64" : "arm";
      } else if (a === "x86") {
        arch = bits === "64" ? "x86_64" : "x86";
      } else if (a === "riscv") {
        arch = "riscv64";
      }

      return buildDetection(os, osLabel, arch, archiveExt);
    } catch (_) {
      return base;
    }
  }

  function getCommands() {
    var isMain = state.channel === "main";
    var isSystem = state.scope === "system";

    var shUrl = PAGES_URL + "/install.sh";
    var psUrl = PAGES_URL + "/install.ps1";

    var unixArgs = [];
    if (isMain) unixArgs.push("--version", "main");
    unixArgs.push(isSystem ? "--system" : "--user");

    var unixSuffix = unixArgs.length ? " -s -- " + unixArgs.join(" ") : "";
    var unixCurl = "curl -fsSL " + shUrl + " | sh" + unixSuffix;
    var unixWget = "wget -qO- " + shUrl + " | sh" + unixSuffix;

    var psScopeFlag = isSystem ? " -Scope Machine" : " -Scope User";
    var psVersionFlag = isMain ? " -Version main" : "";
    var psCmd;
    if (!isMain && !isSystem) {
      psCmd = "irm " + psUrl + " | iex";
    } else {
      psCmd = "& ([scriptblock]::Create((irm " + psUrl + ")))" + psVersionFlag + psScopeFlag;
    }

    var cmdInner = psCmd.replace(/"/g, '\\"');
    var cmdLine = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "' + cmdInner + '"';

    var sourceCmd =
      "git clone " + REPO_URL + ".git\n" +
      "cd ssh-copy-id\n" +
      "zig build -Doptimize=ReleaseSafe\n" +
      "./zig-out/bin/ssh-copy-id --version";

    return {
      unix: {
        main: unixCurl,
        altLabel: "Without curl (using wget):",
        alt: unixWget,
        note: isSystem
          ? "Installs to /usr/local/bin using sudo or doas if needed."
          : "Installs to ~/.local/bin with no admin privileges and updates your shell PATH (~/.profile, ~/.bashrc, ~/.zshrc, or fish)."
      },
      powershell: {
        main: psCmd,
        altLabel: "Inspect script before running:",
        alt: "irm " + psUrl,
        note: isSystem
          ? "Installs to %ProgramFiles%\\ssh-copy-id\\bin and adds it to Machine PATH (requires Administrator PowerShell)."
          : "Installs to %LOCALAPPDATA%\\Programs\\ssh-copy-id\\bin with no admin privileges and adds it to User PATH."
      },
      cmd: {
        main: cmdLine,
        altLabel: "Direct script URL:",
        alt: psUrl,
        note: isSystem
          ? "Invokes install.ps1 for Machine PATH (run Command Prompt as Administrator)."
          : "Invokes install.ps1 for current User PATH without Administrator privileges."
      },
      source: {
        main: sourceCmd,
        altLabel: "Run unit test suite:",
        alt: "zig build test",
        note: "Requires Zig 0.17.1+. Copy zig-out/bin/ssh-copy-id to any directory on your PATH."
      }
    };
  }

  function render() {
    var d = state.detected;
    var detectEl = document.getElementById("detect-summary");
    var detailEl = document.getElementById("detect-detail");

    if (d.os === "unknown") {
      detectEl.textContent = "Platform could not be identified from browser headers.";
      detailEl.textContent = "Suggested: install.sh (auto-detects OS and CPU at runtime)";
    } else if (d.target) {
      detectEl.textContent = "Detected platform: " + d.osLabel + " (" + d.arch + ")";
      detailEl.textContent = "Suggested target: " + d.target;
    } else {
      detectEl.textContent = "Detected platform: " + d.osLabel;
      detailEl.textContent = "CPU architecture hidden by browser; installer detects it at runtime";
    }

    var tabButtons = document.querySelectorAll("[data-tab]");
    tabButtons.forEach(function (btn) {
      var tabId = btn.getAttribute("data-tab");
      var isSelected = tabId === state.tab;
      btn.setAttribute("aria-selected", isSelected ? "true" : "false");

      var existingTag = btn.querySelector(".rec-tag");
      if (tabId === state.suggestedTab) {
        if (!existingTag) {
          var tag = document.createElement("span");
          tag.className = "rec-tag";
          tag.textContent = "suggested";
          btn.appendChild(tag);
        }
      } else if (existingTag) {
        existingTag.remove();
      }
    });

    document.querySelectorAll("[data-channel]").forEach(function (btn) {
      btn.setAttribute("aria-pressed", btn.getAttribute("data-channel") === state.channel ? "true" : "false");
    });

    document.querySelectorAll("[data-scope]").forEach(function (btn) {
      btn.setAttribute("aria-pressed", btn.getAttribute("data-scope") === state.scope ? "true" : "false");
    });

    var cmds = getCommands();
    var active = cmds[state.tab];

    document.getElementById("install-cmd").textContent = active.main;
    document.getElementById("install-alt-label").textContent = active.altLabel;
    document.getElementById("install-alt-cmd").textContent = active.alt;

    var sourceNote = state.channel === "main"
      ? "Pulls the main branch build bundled with this site."
      : "Tries the latest GitHub Release and falls back to the bundled main branch build if no release is published yet.";

    var noteEl = document.getElementById("install-note");
    if (state.tab === "source") {
      noteEl.textContent = active.note;
    } else {
      noteEl.textContent = active.note + " " + sourceNote;
    }
  }

  function copyText(text, btn) {
    var finish = function () {
      var prev = btn.textContent;
      btn.textContent = "Copied";
      setTimeout(function () {
        btn.textContent = prev;
      }, 1400);
    };

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(finish, function () {
        fallbackCopy(text);
        finish();
      });
    } else {
      fallbackCopy(text);
      finish();
    }
  }

  function fallbackCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    try {
      document.execCommand("copy");
    } catch (_) {}
    document.body.removeChild(ta);
  }

  async function loadBuildMetadata() {
    var mainEl = document.getElementById("meta-main-build");
    var relEl = document.getElementById("meta-latest-release");

    try {
      var res = await fetch("./builds/main/manifest.json", { cache: "no-store" });
      if (res.ok) {
        var data = await res.json();
        var shortSha = (data.commit || "").slice(0, 9);
        mainEl.textContent = (data.version || "main") + (shortSha ? " (" + shortSha + ")" : "");
      } else {
        mainEl.textContent = "not bundled in local preview";
      }
    } catch (_) {
      mainEl.textContent = "available on GitHub Pages";
    }

    try {
      var relRes = await fetch("https://api.github.com/repos/dasimmet/ssh-copy-id/releases/latest");
      if (relRes.ok) {
        var rel = await relRes.json();
        relEl.textContent = rel.tag_name || "published";
      } else if (relRes.status === 404) {
        relEl.textContent = "none yet (auto-falls back to main)";
      }
    } catch (_) {
      relEl.textContent = "see GitHub Releases";
    }
  }

  document.addEventListener("DOMContentLoaded", async function () {
    document.querySelectorAll("[data-tab]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        state.tab = btn.getAttribute("data-tab");
        render();
      });
    });

    document.querySelectorAll("[data-channel]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        state.channel = btn.getAttribute("data-channel");
        render();
      });
    });

    document.querySelectorAll("[data-scope]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        state.scope = btn.getAttribute("data-scope");
        render();
      });
    });

    document.getElementById("copy-install-btn").addEventListener("click", function () {
      copyText(document.getElementById("install-cmd").textContent, this);
    });

    document.querySelectorAll("[data-copy-target]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var target = document.getElementById(btn.getAttribute("data-copy-target"));
        if (target) copyText(target.textContent, btn);
      });
    });

    state.detected = await detectPlatformAsync();
    state.suggestedTab = state.detected.os === "windows" ? "powershell" : "unix";
    state.tab = state.suggestedTab;
    render();
    loadBuildMetadata();
  });
})();
