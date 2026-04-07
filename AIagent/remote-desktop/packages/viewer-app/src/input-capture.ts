import type { InputMessage } from "@remote-desktop/shared";

export class InputCapture {
  private channel: RTCDataChannel | null = null;
  private isComposing = false;
  private cleanup: (() => void)[] = [];

  attach(videoEl: HTMLVideoElement, channel: RTCDataChannel): void {
    this.channel = channel;
    this.detach();

    const on = <K extends keyof HTMLElementEventMap>(
      type: K,
      handler: (e: HTMLElementEventMap[K]) => void,
      options?: AddEventListenerOptions
    ) => {
      videoEl.addEventListener(type, handler as EventListener, options);
      this.cleanup.push(() =>
        videoEl.removeEventListener(type, handler as EventListener, options)
      );
    };

    // object-fit: contain 보정 — 실제 비디오 렌더링 영역 계산
    function normalizeCoords(e: MouseEvent): { x: number; y: number } | null {
      const vw = videoEl.videoWidth;
      const vh = videoEl.videoHeight;
      if (!vw || !vh) return null;

      const elW = videoEl.clientWidth;
      const elH = videoEl.clientHeight;
      const elRatio = elW / elH;
      const vidRatio = vw / vh;

      let renderW: number, renderH: number, offsetX: number, offsetY: number;
      if (vidRatio > elRatio) {
        renderW = elW;
        renderH = elW / vidRatio;
        offsetX = 0;
        offsetY = (elH - renderH) / 2;
      } else {
        renderH = elH;
        renderW = elH * vidRatio;
        offsetX = (elW - renderW) / 2;
        offsetY = 0;
      }

      const x = (e.offsetX - offsetX) / renderW;
      const y = (e.offsetY - offsetY) / renderH;

      if (x < 0 || x > 1 || y < 0 || y > 1) return null;
      return { x, y };
    }

    on("mousemove", (e: MouseEvent) => {
      const coords = normalizeCoords(e);
      if (coords) {
        this.sendInput({ type: "mousemove", x: coords.x, y: coords.y });
      }
    });

    on("mousedown", (e: MouseEvent) => {
      this.sendInput({ type: "mousedown", button: e.button });
    });

    on("mouseup", (e: MouseEvent) => {
      this.sendInput({ type: "mouseup", button: e.button });
    });

    on("wheel", (e: WheelEvent) => {
      e.preventDefault();
      this.sendInput({ type: "scroll", deltaX: e.deltaX, deltaY: e.deltaY });
    }, { passive: false });

    on("contextmenu", (e: MouseEvent) => {
      e.preventDefault();
    });

    on("compositionstart", () => {
      this.isComposing = true;
    });

    on("compositionend", (e: CompositionEvent) => {
      this.isComposing = false;
      if (e.data) {
        this.sendInput({ type: "text-input", text: e.data });
      }
    });

    on("keydown", (e: KeyboardEvent) => {
      e.preventDefault();
      if (this.isComposing) return;

      const modifiers: string[] = [];
      if (e.ctrlKey) modifiers.push("ctrl");
      if (e.shiftKey) modifiers.push("shift");
      if (e.altKey) modifiers.push("alt");
      if (e.metaKey) modifiers.push("meta");

      this.sendInput({ type: "keydown", key: e.key, code: e.code, modifiers });
    });

    on("keyup", (e: KeyboardEvent) => {
      e.preventDefault();
      if (this.isComposing) return;
      this.sendInput({ type: "keyup", key: e.key, code: e.code });
    });
  }

  detach(): void {
    for (const fn of this.cleanup) fn();
    this.cleanup = [];
    this.isComposing = false;
  }

  private sendInput(msg: InputMessage): void {
    if (this.channel?.readyState === "open") {
      this.channel.send(JSON.stringify(msg));
    }
  }
}
