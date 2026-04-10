import type { IncomingMessage, ServerResponse } from "http";
import { createReadStream, existsSync, statSync } from "fs";
import { resolve } from "path";
import { execSync } from "child_process";
import { log } from "./logger.js";

const WIN_RELEASE_DIR = resolve(process.cwd(), "../host-app-flutter/build/windows/x64/runner/Release");
const WIN_ZIP = resolve(process.cwd(), "../host-app-flutter/build/RemoteCall-mini-Host-Windows.zip");
const MAC_RELEASE_DIR = resolve(process.cwd(), "../host-app-flutter/build/macos/Build/Products/Release");
const MAC_ZIP = resolve(process.cwd(), "../host-app-flutter/build/RemoteCall-mini-Host-macOS.zip");

const DOWNLOAD_PAGE_HTML = `<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>RemoteCall-mini - 호스트 앱 다운로드</title>
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
      font-size: 24px; font-weight: 700; margin-bottom: 8px;
      background: linear-gradient(135deg, #4f8ef7, #8b5cf6);
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    }
    .subtitle { color: #8b90a4; font-size: 14px; margin-bottom: 28px; }
    .download-section { display: flex; gap: 12px; margin-bottom: 16px; }
    .download-btn {
      display: flex; flex-direction: column; align-items: center; gap: 6px;
      flex: 1; background: linear-gradient(135deg, #4f8ef7, #6366f1);
      color: #fff; text-decoration: none; padding: 16px 12px; border-radius: 10px;
      font-size: 14px; font-weight: 700;
      box-shadow: 0 4px 14px rgba(79,142,247,0.3);
      transition: box-shadow 0.15s, transform 0.15s;
    }
    .download-btn:hover { box-shadow: 0 6px 20px rgba(79,142,247,0.45); transform: translateY(-1px); }
    .download-btn .os-icon { font-size: 28px; }
    .download-btn .os-label { font-size: 11px; font-weight: 500; opacity: 0.8; }
    .download-btn.recommended { border: 2px solid #4ff77e; }
    .badge { display: inline-block; background: #4ff77e; color: #0f1117; font-size: 9px; font-weight: 700; padding: 1px 6px; border-radius: 3px; margin-top: 2px; }
    .info { margin-top: 20px; font-size: 12px; color: #8b90a4; line-height: 1.6; }
    .steps { text-align: left; margin-top: 20px; }
    .steps h3 { font-size: 13px; color: #e8eaf0; margin-bottom: 8px; }
    .steps ol { padding-left: 20px; font-size: 12px; color: #8b90a4; line-height: 2; }
    .tab-btns { display: flex; gap: 8px; margin-bottom: 16px; justify-content: center; }
    .tab-btn { background: #2e3347; border: none; color: #8b90a4; padding: 6px 16px; border-radius: 6px; font-size: 12px; cursor: pointer; }
    .tab-btn.active { background: #4f8ef7; color: #fff; }
    .tab-content { display: none; }
    .tab-content.active { display: block; }
  </style>
</head>
<body>
  <div class="card">
    <h1>RemoteCall-mini</h1>
    <p class="subtitle">원격지원 호스트 앱</p>

    <div class="download-section">
      <a href="/download/windows" class="download-btn" id="btn-win">
        <span class="os-icon">&#x1fa9f;</span>
        <span>Windows</span>
        <span class="os-label">x64 ZIP</span>
      </a>
      <a href="/download/macos" class="download-btn" id="btn-mac">
        <span class="os-icon">&#x1f34e;</span>
        <span>macOS</span>
        <span class="os-label">App ZIP</span>
      </a>
    </div>

    <div class="tab-btns">
      <button class="tab-btn active" onclick="showTab('win')">Windows</button>
      <button class="tab-btn" onclick="showTab('mac')">macOS</button>
    </div>

    <div id="tab-win" class="tab-content active">
      <div class="steps">
        <h3>Windows 설치 방법</h3>
        <ol>
          <li>Windows 버튼을 클릭하여 ZIP을 다운로드합니다.</li>
          <li>ZIP 파일의 압축을 해제합니다.</li>
          <li><strong>host_app_flutter.exe</strong>를 실행합니다.</li>
          <li>중계서버 주소에 <strong>ws://서버IP:8080</strong>을 입력합니다.</li>
          <li>접속번호 6자리를 입력하면 자동으로 연결됩니다.</li>
        </ol>
      </div>
    </div>

    <div id="tab-mac" class="tab-content">
      <div class="steps">
        <h3>macOS 설치 방법</h3>
        <ol>
          <li>macOS 버튼을 클릭하여 ZIP을 다운로드합니다.</li>
          <li>ZIP 파일의 압축을 해제합니다.</li>
          <li><strong>host_app_flutter.app</strong>을 응용 프로그램 폴더로 이동합니다.</li>
          <li>앱 실행 시 "확인되지 않은 개발자" 경고가 뜨면:<br>
              시스템 설정 > 개인 정보 보호 및 보안 > "확인 없이 열기" 클릭</li>
          <li>중계서버 주소에 <strong>ws://서버IP:8080</strong>을 입력합니다.</li>
          <li>접속번호 6자리를 입력하면 자동으로 연결됩니다.</li>
        </ol>
      </div>
    </div>

    <p class="info">v1.0.0 | Windows 10/11 x64 · macOS 12+</p>
  </div>

  <script>
    // OS 자동 감지하여 추천 표시
    const isMac = navigator.platform.toUpperCase().indexOf('MAC') >= 0;
    const recommended = document.getElementById(isMac ? 'btn-mac' : 'btn-win');
    if (recommended) {
      recommended.classList.add('recommended');
      recommended.innerHTML += '<span class="badge">추천</span>';
    }
    if (isMac) showTab('mac');

    function showTab(os) {
      document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
      document.querySelectorAll('.tab-btn').forEach(el => el.classList.remove('active'));
      document.getElementById('tab-' + os).classList.add('active');
      event.target?.classList?.add('active');
    }
  </script>
</body>
</html>`;

function ensureWinZip(): boolean {
  if (!existsSync(WIN_RELEASE_DIR)) return false;
  if (existsSync(WIN_ZIP)) return true;
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

  return false;
}
