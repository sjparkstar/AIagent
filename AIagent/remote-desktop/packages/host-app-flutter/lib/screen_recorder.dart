import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// FFmpeg를 사용한 Windows 화면 녹화 서비스
/// 뷰어가 DataChannel로 녹화 시작/중단을 요청하면 호스트에서 실행
class ScreenRecorder {
  Process? _ffmpegProcess;
  String? _outputPath;
  bool _isRecording = false;

  bool get isRecording => _isRecording;
  String? get outputPath => _outputPath;

  /// ffmpeg 실행 경로 탐색: 앱과 함께 번들된 ffmpeg.exe 우선, 없으면 PATH
  /// release 빌드: exe와 같은 폴더에 ffmpeg.exe가 설치됨 (CMakeLists.txt 참고)
  /// debug 빌드: build/windows/x64/runner/Debug/ffmpeg.exe
  static String _findFfmpegPath() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = File('$exeDir\\ffmpeg.exe');
      if (bundled.existsSync()) {
        debugPrint('[recorder] 번들된 ffmpeg 사용: ${bundled.path}');
        return bundled.path;
      }
    } catch (e) {
      debugPrint('[recorder] 번들 ffmpeg 경로 탐색 실패: $e');
    }
    // PATH에 등록된 ffmpeg 사용
    return 'ffmpeg';
  }

  /// FFmpeg 실행 가능 여부 확인
  static Future<bool> isAvailable() async {
    try {
      final result = await Process.run(_findFfmpegPath(), ['-version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 화면 녹화 시작 (FFmpeg gdigrab 사용)
  Future<bool> start({String? sessionId}) async {
    if (_isRecording) return true;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final id = sessionId ?? DateTime.now().millisecondsSinceEpoch.toString();
      _outputPath = '${dir.path}/recording-$id.mp4';

      // FFmpeg gdigrab: Windows 데스크톱 전체 화면 캡처
      // -y: 덮어쓰기, -f gdigrab: Windows GDI 캡처
      // -framerate 15: 15fps (원격 제어용 적정 수준)
      // -i desktop: 전체 화면
      // -c:v libx264: H.264 코덱 (호환성 최고)
      // -preset ultrafast: 인코딩 속도 최우선 (CPU 부하 최소)
      // -crf 28: 품질 (높을수록 낮은 품질, 작은 파일)
      _ffmpegProcess = await Process.start(_findFfmpegPath(), [
        '-y',
        '-f', 'gdigrab',
        '-framerate', '15',
        '-i', 'desktop',
        '-c:v', 'libx264',
        '-preset', 'ultrafast',
        '-crf', '28',
        '-pix_fmt', 'yuv420p',
        _outputPath!,
      ]);

      _isRecording = true;
      debugPrint('[recorder] 녹화 시작: $_outputPath');

      // stderr 로그 (FFmpeg 진행 상황)
      _ffmpegProcess!.stderr.transform(const SystemEncoding().decoder).listen(
        (line) => debugPrint('[ffmpeg] $line'),
      );

      return true;
    } catch (e) {
      debugPrint('[recorder] 녹화 시작 실패: $e');
      _isRecording = false;
      return false;
    }
  }

  /// 녹화 중단 — FFmpeg에 'q' 입력으로 정상 종료
  Future<String?> stop() async {
    if (!_isRecording || _ffmpegProcess == null) return null;

    try {
      // FFmpeg에 'q' 입력하여 정상 종료 (파일 마무리)
      _ffmpegProcess!.stdin.write('q');
      await _ffmpegProcess!.stdin.flush();

      // 최대 10초 대기
      final exitCode = await _ffmpegProcess!.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _ffmpegProcess!.kill();
          return -1;
        },
      );

      debugPrint('[recorder] 녹화 종료: exitCode=$exitCode, path=$_outputPath');
      _isRecording = false;

      final path = _outputPath;
      _ffmpegProcess = null;

      // 파일이 존재하는지 확인
      if (path != null && await File(path).exists()) {
        final size = await File(path).length();
        debugPrint('[recorder] 파일 크기: ${(size / 1024 / 1024).toStringAsFixed(1)}MB');
        return path;
      }
      return null;
    } catch (e) {
      debugPrint('[recorder] 녹화 중단 실패: $e');
      _isRecording = false;
      _ffmpegProcess?.kill();
      _ffmpegProcess = null;
      return null;
    }
  }

  /// 리소스 정리
  void dispose() {
    if (_isRecording) {
      _ffmpegProcess?.kill();
      _isRecording = false;
      _ffmpegProcess = null;
    }
  }
}
