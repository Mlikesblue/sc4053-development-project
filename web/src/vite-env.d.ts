/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_FACTORY_ANVIL_ADDRESS: string;
  readonly VITE_FACTORY_SEPOLIA_ADDRESS: string;
  readonly VITE_SEPOLIA_RPC_URL: string;
  readonly VITE_ANVIL_DEPLOYMENT_BLOCK: string;
  readonly VITE_SEPOLIA_DEPLOYMENT_BLOCK: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
