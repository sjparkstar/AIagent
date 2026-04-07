import { clipboard } from "electron";
import type { InputMessage } from "@remote-desktop/shared";

let robot: typeof import("@jitsi/robotjs") | null = null;

try {
  robot = require("@jitsi/robotjs");
} catch {
  console.warn("[input] @jitsi/robotjs not available, input injection disabled");
}

const MOUSE_BUTTON_MAP: Record<number, string> = {
  0: "left",
  1: "middle",
  2: "right",
};

let activeBounds = { x: 0, y: 0, width: 1920, height: 1080 };
let activeScaleFactor = 1;

export function setActiveBounds(bounds: { x: number; y: number; width: number; height: number }, scaleFactor: number): void {
  activeBounds = bounds;
  activeScaleFactor = scaleFactor;
}

function getAbsoluteCoords(normalizedX: number, normalizedY: number): { x: number; y: number } {
  // display.bounds는 논리적 좌표(DIP), robotjs는 물리적 좌표를 사용할 수 있으므로 scaleFactor 적용
  const sf = activeScaleFactor;
  return {
    x: Math.round((activeBounds.x + normalizedX * activeBounds.width) * sf),
    y: Math.round((activeBounds.y + normalizedY * activeBounds.height) * sf),
  };
}

async function injectTextViaClipboard(text: string): Promise<void> {
  if (!robot) return;
  const previous = clipboard.readText();
  clipboard.writeText(text);
  robot.keyTap("v", ["control"]);
  await new Promise<void>((resolve) => setTimeout(resolve, 100));
  clipboard.writeText(previous);
}

export async function injectInput(msg: InputMessage): Promise<void> {
  if (!robot) return;

  switch (msg.type) {
    case "mousemove": {
      const { x, y } = getAbsoluteCoords(msg.x, msg.y);
      robot.moveMouse(x, y);
      break;
    }
    case "mousedown": {
      const button = MOUSE_BUTTON_MAP[msg.button] ?? "left";
      robot.mouseToggle("down", button);
      break;
    }
    case "mouseup": {
      const button = MOUSE_BUTTON_MAP[msg.button] ?? "left";
      robot.mouseToggle("up", button);
      break;
    }
    case "scroll": {
      robot.scrollMouse(Math.round(msg.deltaX), Math.round(msg.deltaY));
      break;
    }
    case "keydown": {
      const modifiers = msg.modifiers.map((m) => m.toLowerCase());
      if (modifiers.length > 0) {
        robot.keyToggle(msg.key.toLowerCase(), "down", modifiers);
      } else {
        robot.keyToggle(msg.key.toLowerCase(), "down");
      }
      break;
    }
    case "keyup": {
      robot.keyToggle(msg.key.toLowerCase(), "up");
      break;
    }
    case "text-input": {
      await injectTextViaClipboard(msg.text);
      break;
    }
    case "clipboard-sync": {
      clipboard.writeText(msg.text);
      break;
    }
  }
}
