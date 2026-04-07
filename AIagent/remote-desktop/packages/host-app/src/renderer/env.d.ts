/// <reference types="vite/client" />

import type { HostAPI } from "../shared-types";

declare global {
  interface Window {
    hostAPI: HostAPI;
  }
}
