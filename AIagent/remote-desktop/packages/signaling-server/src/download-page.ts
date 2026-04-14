import type { IncomingMessage, ServerResponse } from "http";
import { createReadStream, existsSync, statSync } from "fs";
import { resolve } from "path";
import { execSync } from "child_process";
import { log } from "./logger.js";

const WIN_RELEASE_DIR = resolve(process.cwd(), "../host-app-flutter/build/windows/x64/runner/Release");
const WIN_ZIP = resolve(process.cwd(), "../host-app-flutter/build/RemoteCall-mini-Host-Windows.zip");
const MAC_RELEASE_DIR = resolve(process.cwd(), "../host-app-flutter/build/macos/Build/Products/Release");
const MAC_ZIP = resolve(process.cwd(), "../host-app-flutter/build/RemoteCall-mini-Host-macOS.zip");

const VIEWER_WIN_RELEASE_DIR = resolve(process.cwd(), "../viewer-app-flutter/build/windows/x64/runner/Release");
const VIEWER_WIN_ZIP = resolve(process.cwd(), "../viewer-app-flutter/build/RemoteCall-mini-Viewer-Windows.zip");
const VIEWER_MAC_RELEASE_DIR = resolve(process.cwd(), "../viewer-app-flutter/build/macos/Build/Products/Release");
const VIEWER_MAC_ZIP = resolve(process.cwd(), "../viewer-app-flutter/build/RemoteCall-mini-Viewer-macOS.zip");

const DOWNLOAD_PAGE_HTML = `<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>RemoteCall-mini - 앱 다운로드</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0f1117; color: #e8eaf0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh;
    }
    .card {
      background: #1e2130; border: 1px solid #2e3347; border-radius: 16px;
      padding: 48px 40px; width: 90%; max-width: 520px; text-align: center;
      box-shadow: 0 8px 32px rgba(0,0,0,0.3);
    }
    h1 {
      font-size: 24px; font-weight: 700; margin-bottom: 4px;
      background: linear-gradient(135deg, #4f8ef7, #8b5cf6);
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    }
    .os-detect { color: #4ff77e; font-size: 12px; font-weight: 500; margin-bottom: 24px; }
    .section-title { font-size: 15px; font-weight: 600; color: #e8eaf0; margin-bottom: 12px; }
    .download-btn {
      display: flex; align-items: center; gap: 12px;
      width: 100%; background: linear-gradient(135deg, #4f8ef7, #6366f1);
      color: #fff; text-decoration: none; padding: 14px 20px; border-radius: 10px;
      font-size: 14px; font-weight: 600; margin-bottom: 10px;
      box-shadow: 0 4px 14px rgba(79,142,247,0.3);
      transition: box-shadow 0.15s, transform 0.15s;
    }
    .download-btn:hover { box-shadow: 0 6px 20px rgba(79,142,247,0.45); transform: translateY(-1px); }
    .download-btn .os-icon { font-size: 24px; }
    .download-btn .btn-info { text-align: left; }
    .download-btn .btn-label { font-size: 11px; opacity: 0.7; }
    .divider { margin: 24px 0; border-top: 1px solid #2e3347; }
    .steps { text-align: left; margin-top: 16px; }
    .steps h3 { font-size: 13px; color: #e8eaf0; margin-bottom: 8px; }
    .steps ol { padding-left: 20px; font-size: 12px; color: #8b90a4; line-height: 2; }
    .info { margin-top: 20px; font-size: 12px; color: #8b90a4; line-height: 1.6; }
    .toggle-other { background: none; border: 1px solid #2e3347; color: #8b90a4; padding: 6px 16px; border-radius: 6px; font-size: 11px; cursor: pointer; margin-top: 16px; }
    .toggle-other:hover { border-color: #4f8ef7; color: #e8eaf0; }
    .other-os { display: none; margin-top: 16px; padding-top: 16px; border-top: 1px solid #2e3347; }
    .other-os.show { display: block; }
    .other-os .download-btn { background: #2e3347; box-shadow: none; font-size: 13px; padding: 10px 16px; }
    .other-os .download-btn:hover { background: #3a3f56; }
  </style>
</head>
<body>
  <div class="card">
    <h1>RemoteCall-mini</h1>
    <p class="os-detect" id="os-detect"></p>

    <!-- 호스트 앱 -->
    <div class="section-title">호스트 앱</div>
    <a href="/download/windows" class="download-btn os-win" id="btn-host-win">
      <span class="os-icon">&#x1fa9f;</span>
      <div class="btn-info"><span>호스트 앱 다운로드</span><br><span class="btn-label">Windows x64 ZIP</span></div>
    </a>
    <a href="/download/macos" class="download-btn os-mac" id="btn-host-mac">
      <span class="os-icon">&#x1f34e;</span>
      <div class="btn-info"><span>호스트 앱 다운로드</span><br><span class="btn-label">macOS App ZIP</span></div>
    </a>

    <div class="divider"></div>

    <!-- 뷰어 앱 -->
    <div class="section-title">뷰어 앱</div>
    <a href="/download/viewer-windows" class="download-btn os-win" id="btn-viewer-win">
      <span class="os-icon">&#x1fa9f;</span>
      <div class="btn-info"><span>뷰어 앱 다운로드</span><br><span class="btn-label">Windows x64 ZIP</span></div>
    </a>
    <a href="/download/viewer-macos" class="download-btn os-mac" id="btn-viewer-mac">
      <span class="os-icon">&#x1f34e;</span>
      <div class="btn-info"><span>뷰어 앱 다운로드</span><br><span class="btn-label">macOS App ZIP</span></div>
    </a>

    <!-- 설치 안내 -->
    <div id="steps-win" class="steps os-win">
      <h3>Windows 설치 방법</h3>
      <ol>
        <li>다운로드한 ZIP 파일의 압축을 해제합니다.</li>
        <li><strong>.exe</strong> 파일을 실행합니다.</li>
        <li>호스트 앱: 중계서버 주소 입력 후 접속번호 6자리로 연결</li>
        <li>뷰어 앱: 상담 연결 버튼으로 원격 지원 시작</li>
      </ol>
    </div>
    <div id="steps-mac" class="steps os-mac">
      <h3>macOS 설치 방법</h3>
      <ol>
        <li>다운로드한 ZIP 파일의 압축을 해제합니다.</li>
        <li><strong>.app</strong> 파일을 응용 프로그램 폴더로 이동합니다.</li>
        <li>"확인되지 않은 개발자" 경고 시: 시스템 설정 > 보안 > "확인 없이 열기"</li>
        <li>호스트 앱: 중계서버 주소 입력 후 접속번호 6자리로 연결</li>
      </ol>
    </div>

    <p class="info">v1.0.0 | Windows 10/11 x64 · macOS 12+</p>

    <!-- 다른 OS 다운로드 토글 -->
    <button class="toggle-other" id="toggle-other">다른 OS 다운로드 보기</button>
    <div class="other-os" id="other-os">
      <div id="other-host-win" class="other-win">
        <a href="/download/windows" class="download-btn">&#x1fa9f; 호스트 - Windows</a>
      </div>
      <div id="other-host-mac" class="other-mac">
        <a href="/download/macos" class="download-btn">&#x1f34e; 호스트 - macOS</a>
      </div>
      <div id="other-viewer-win" class="other-win">
        <a href="/download/viewer-windows" class="download-btn">&#x1fa9f; 뷰어 - Windows</a>
      </div>
      <div id="other-viewer-mac" class="other-mac">
        <a href="/download/viewer-macos" class="download-btn">&#x1f34e; 뷰어 - macOS</a>
      </div>
    </div>
  </div>

  <script>
    const isMac = /Mac|iPhone|iPad|iPod/.test(navigator.userAgent);
    const osName = isMac ? 'macOS' : 'Windows';
    document.getElementById('os-detect').textContent = osName + ' 감지됨 — ' + osName + '용 다운로드를 표시합니다.';

    // 현재 OS에 맞는 버튼만 표시
    const hideClass = isMac ? 'os-win' : 'os-mac';
    document.querySelectorAll('.' + hideClass).forEach(el => el.style.display = 'none');

    // 다른 OS 토글에서 현재 OS 것은 숨김 (이미 위에 보이므로)
    const otherHideClass = isMac ? 'other-mac' : 'other-win';
    document.querySelectorAll('.' + otherHideClass).forEach(el => el.style.display = 'none');

    document.getElementById('toggle-other').addEventListener('click', function() {
      const el = document.getElementById('other-os');
      const show = !el.classList.contains('show');
      el.classList.toggle('show', show);
      this.textContent = show ? '다른 OS 다운로드 숨기기' : '다른 OS 다운로드 보기';
    });
  </script>
</body>
</html>`;

function ensureWinZip(): boolean {
  if (!existsSync(WIN_RELEASE_DIR)) return false;
  const exePath = resolve(WIN_RELEASE_DIR, "host_app_flutter.exe");
  if (existsSync(WIN_ZIP) && existsSync(exePath)) {
    const zipTime = statSync(WIN_ZIP).mtimeMs;
    const exeTime = statSync(exePath).mtimeMs;
    if (zipTime >= exeTime) return true;
    log("[download] Host Windows 빌드가 ZIP보다 새로움 — 재생성");
  }
  try {
    log("[download] Windows ZIP 생성 중...");
    execSync(`powershell -NoProfile -Command "Compress-Archive -Path '${WIN_RELEASE_DIR}\\*' -DestinationPath '${WIN_ZIP}' -Force"`, { timeout: 60000, windowsHide: true });
    return true;
  } catch (e) { log(`[download] Windows ZIP 생성 실패: ${e}`); return false; }
}

function ensureMacZip(): boolean {
  if (!existsSync(MAC_RELEASE_DIR)) return false;
  if (existsSync(MAC_ZIP)) return true;
  try {
    log("[download] macOS ZIP 생성 중...");
    execSync(`powershell -NoProfile -Command "Compress-Archive -Path '${MAC_RELEASE_DIR}\\*' -DestinationPath '${MAC_ZIP}' -Force"`, { timeout: 60000, windowsHide: true });
    return true;
  } catch (e) { log(`[download] macOS ZIP 생성 실패: ${e}`); return false; }
}

function ensureViewerWinZip(): boolean {
  if (!existsSync(VIEWER_WIN_RELEASE_DIR)) return false;
  // 빌드가 ZIP보다 새로우면 ZIP을 다시 생성
  const exePath = resolve(VIEWER_WIN_RELEASE_DIR, "viewer_app_flutter.exe");
  if (existsSync(VIEWER_WIN_ZIP) && existsSync(exePath)) {
    const zipTime = statSync(VIEWER_WIN_ZIP).mtimeMs;
    const exeTime = statSync(exePath).mtimeMs;
    if (zipTime >= exeTime) return true;
    log("[download] Viewer Windows 빌드가 ZIP보다 새로움 — 재생성");
  }
  try {
    log("[download] Viewer Windows ZIP 생성 중...");
    execSync(`powershell -NoProfile -Command "Compress-Archive -Path '${VIEWER_WIN_RELEASE_DIR}\\*' -DestinationPath '${VIEWER_WIN_ZIP}' -Force"`, { timeout: 60000, windowsHide: true });
    return true;
  } catch (e) { log(`[download] Viewer Windows ZIP 생성 실패: ${e}`); return false; }
}

function ensureViewerMacZip(): boolean {
  if (!existsSync(VIEWER_MAC_RELEASE_DIR)) return false;
  if (existsSync(VIEWER_MAC_ZIP)) return true;
  try {
    log("[download] Viewer macOS ZIP 생성 중...");
    execSync(`powershell -NoProfile -Command "Compress-Archive -Path '${VIEWER_MAC_RELEASE_DIR}\\*' -DestinationPath '${VIEWER_MAC_ZIP}' -Force"`, { timeout: 60000, windowsHide: true });
    return true;
  } catch (e) { log(`[download] Viewer macOS ZIP 생성 실패: ${e}`); return false; }
}

function serveZip(res: ServerResponse, zipPath: string, filename: string): void {
  const stat = statSync(zipPath);
  res.writeHead(200, {
    "Content-Type": "application/zip",
    "Content-Disposition": `attachment; filename=${filename}`,
    "Content-Length": stat.size,
    "Access-Control-Allow-Origin": "*",
  });
  createReadStream(zipPath).pipe(res);
  log(`[download] ${filename} 다운로드 시작 (${Math.round(stat.size / 1048576)}MB)`);
}

export function handleDownloadPage(req: IncomingMessage, res: ServerResponse): boolean {
  const url = req.url ?? "";

  if (url === "/download" || url === "/download/") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Access-Control-Allow-Origin": "*" });
    res.end(DOWNLOAD_PAGE_HTML);
    return true;
  }

  if (url === "/download/windows" || url === "/download/host-app") {
    if (!ensureWinZip()) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("Windows 빌드가 없습니다.\nflutter build windows --release 실행 후 다시 시도하세요.");
      return true;
    }
    serveZip(res, WIN_ZIP, "RemoteCall-mini-Host-Windows.zip");
    return true;
  }

  if (url === "/download/macos") {
    if (!ensureMacZip()) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("macOS 빌드가 없습니다.\nmacOS에서 flutter build macos --release 실행 후 빌드 결과를 서버에 배치하세요.");
      return true;
    }
    serveZip(res, MAC_ZIP, "RemoteCall-mini-Host-macOS.zip");
    return true;
  }

  if (url === "/download/viewer-windows") {
    if (!ensureViewerWinZip()) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("뷰어 Windows 빌드가 없습니다.\nflutter build windows --release 실행 후 다시 시도하세요.");
      return true;
    }
    serveZip(res, VIEWER_WIN_ZIP, "RemoteCall-mini-Viewer-Windows.zip");
    return true;
  }

  if (url === "/download/viewer-macos") {
    if (!ensureViewerMacZip()) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("뷰어 macOS 빌드가 없습니다.");
      return true;
    }
    serveZip(res, VIEWER_MAC_ZIP, "RemoteCall-mini-Viewer-macOS.zip");
    return true;
  }

  return false;
}
