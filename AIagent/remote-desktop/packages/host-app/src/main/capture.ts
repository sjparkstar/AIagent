import { desktopCapturer, screen } from "electron";

export interface ScreenSource {
  id: string;
  name: string;
  thumbnailDataUrl: string;
  bounds: { x: number; y: number; width: number; height: number };
  scaleFactor: number;
}

export async function getScreenSources(): Promise<ScreenSource[]> {
  const sources = await desktopCapturer.getSources({
    types: ["screen"],
    thumbnailSize: { width: 320, height: 180 },
  });

  const displays = screen.getAllDisplays();

  return sources.map((source, index) => {
    // desktopCapturer sources와 getAllDisplays()의 순서가 일반적으로 일치
    const display = displays[index] ?? screen.getPrimaryDisplay();
    return {
      id: source.id,
      name: source.name,
      thumbnailDataUrl: source.thumbnail.toDataURL(),
      bounds: display.bounds,
      scaleFactor: display.scaleFactor,
    };
  });
}
