import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  http,
  parseAbiItem,
  type Address,
  type PublicClient,
  type WalletClient,
} from "viem";
import { sepolia } from "viem/chains";

import factoryAbiJson from "./abi/AuctionFactory.json";
import auctionAbiJson from "./abi/DutchAuction.json";
import tokenAbiJson from "./abi/AuctionToken.json";

export const factoryAbi = factoryAbiJson as any;
export const auctionAbi = auctionAbiJson as any;
export const tokenAbi = tokenAbiJson as any;

export const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
  },
});

export type NetworkKey = "anvil" | "sepolia";
export const networks: Record<NetworkKey, typeof anvil | typeof sepolia> = {
  anvil,
  sepolia,
};

export function factoryAddressFor(network: NetworkKey): Address | undefined {
  const raw = network === "anvil"
    ? import.meta.env.VITE_FACTORY_ANVIL_ADDRESS
    : import.meta.env.VITE_FACTORY_SEPOLIA_ADDRESS;
  return raw && /^0x[0-9a-fA-F]{40}$/.test(raw) ? (raw as Address) : undefined;
}

export function publicClientFor(network: NetworkKey): PublicClient | undefined {
  const rpcUrl = network === "anvil"
    ? "http://127.0.0.1:8545"
    : import.meta.env.VITE_SEPOLIA_RPC_URL;
  if (!rpcUrl) return undefined;

  // Sepolia has Multicall3 deployed at the canonical address, so viem can
  // aggregate every readContract call this app issues during a refresh into a
  // single eth_call. This keeps Alchemy's free-tier compute-units-per-second
  // limit comfortably out of reach on an account or network switch.
  //
  // Anvil does not ship with Multicall3 by default, so we stick with plain
  // JSON-RPC batching there; localhost latency makes the volume irrelevant.
  if (network === "sepolia") {
    return createPublicClient({
      chain: sepolia,
      transport: http(rpcUrl, {
        batch: { batchSize: 100, wait: 50 },
        retryCount: 3,
        retryDelay: 500,
      }),
      batch: { multicall: { batchSize: 1024, wait: 50 } },
    });
  }

  return createPublicClient({
    chain: anvil,
    transport: http(rpcUrl, { batch: { batchSize: 100, wait: 16 } }),
  });
}

export function walletClientFor(network: NetworkKey, ethereum: EthereumProvider): WalletClient {
  return createWalletClient({
    account: undefined,
    chain: networks[network] as typeof anvil,
    transport: custom(ethereum),
  });
}

export const activityEvents = {
  bid: parseAbiItem(
    "event BidCommitted(address indexed bidder, uint256 indexed commitmentIndex, uint256 acceptedWei, uint256 excessWei, uint256 timestamp)",
  ),
  claim: parseAbiItem(
    "event Claimed(address indexed bidder, uint256 tokenAmount, uint256 refundWei)",
  ),
  refund: parseAbiItem(
    "event RefundWithdrawn(address indexed bidder, address indexed recipient, uint256 amountWei)",
  ),
  proceeds: parseAbiItem("event ProceedsWithdrawn(address indexed admin, uint256 amountWei)"),
};

export interface EthereumProvider {
  request(args: { method: string; params?: unknown[] | object }): Promise<unknown>;
  on?(event: string, callback: (...args: any[]) => void): void;
}

declare global {
  interface Window {
    ethereum?: EthereumProvider;
  }
}

export type AuctionStatus = "Scheduled" | "Open" | "Capacity reached" | "Closed" | "Finalized" | "Cancelled";

export interface AuctionView {
  address: Address;
  token: Address;
  name: string;
  symbol: string;
  decimals: number;
  curve: number;
  status: AuctionStatus;
  rawStatus: number;
  startTime: bigint;
  endTime: bigint;
  tokenSupply: bigint;
  startingPrice: bigint;
  reservePrice: bigint;
  currentPrice: bigint;
  closingTime: bigint;
  closingPrice: bigint;
  totalAccepted: bigint;
  cap: bigint;
  commitments: bigint;
  walletAccepted: bigint;
  walletTokens: bigint;
  walletRefund: bigint;
  claimed: boolean;
  refundClaimed: boolean;
  proceeds: bigint;
  refundLiability: bigint;
  finalPrice: bigint;
  finalTime: bigint;
}

export async function call(
  client: PublicClient,
  address: Address,
  abi: any,
  functionName: string,
  args: unknown[] = [],
): Promise<any> {
  return client.readContract({
    address,
    abi,
    functionName,
    args,
  } as any);
}

export function statusLabel(value: number): AuctionStatus {
  return (
    ["Scheduled", "Open", "Capacity reached", "Closed", "Finalized", "Cancelled"][value] as
      | AuctionStatus
      | undefined
  ) ?? "Closed";
}

export async function readAuctions(
  client: PublicClient,
  factoryAddress: Address,
  account?: Address,
): Promise<AuctionView[]> {
  const count = Number(await call(client, factoryAddress, factoryAbi, "auctionCount"));
  const auctionAddresses = await Promise.all(
    Array.from({ length: count }, (_, index) =>
      call(client, factoryAddress, factoryAbi, "auctionAt", [BigInt(index)]),
    ),
  );

  return Promise.all(
    (auctionAddresses as Address[]).map(async (address) => {
      const view = (name: string, args: unknown[] = []) =>
        call(client, address, auctionAbi, name, args);
      const [
        token,
        rawStatus,
        curve,
        startTime,
        tokenSupply,
        startingPrice,
        reservePrice,
        currentPrice,
        closingTime,
        closingPrice,
        totalAccepted,
        cap,
        commitments,
        proceeds,
        proceedsWithdrawn,
        refundLiability,
        finalPrice,
        finalTime,
      ] = await Promise.all([
        view("token"),
        view("status"),
        view("curve"),
        view("startTime"),
        view("tokenSupply"),
        view("startingPriceWeiPerToken"),
        view("reservePriceWeiPerToken"),
        view("currentPrice"),
        view("logicalClosingTime"),
        view("logicalClosingPrice"),
        view("totalAcceptedEth"),
        view("commitmentCap"),
        view("commitmentCount"),
        view("totalSaleProceeds"),
        view("proceedsWithdrawn"),
        view("totalRefundLiability"),
        view("finalPriceWeiPerToken"),
        view("finalTimestamp"),
      ]);
      const tokenAddress = token as Address;
      const [name, symbol, decimals, walletAccepted, walletTokens, walletRefund, claimed, refundClaimed] =
        await Promise.all([
          call(client, tokenAddress, tokenAbi, "name"),
          call(client, tokenAddress, tokenAbi, "symbol"),
          call(client, tokenAddress, tokenAbi, "decimals"),
          account ? view("grossAcceptedWei", [account]) : 0n,
          account ? view("tokenEntitlement", [account]) : 0n,
          account ? view("refundEntitlement", [account]) : 0n,
          account ? view("tokensClaimed", [account]) : false,
          account ? view("refundClaimed", [account]) : false,
        ]);
      const end = (startTime as bigint) + 1_200n;

      return {
        address,
        token: tokenAddress,
        name: name as string,
        symbol: symbol as string,
        decimals: Number(decimals),
        curve: Number(curve),
        rawStatus: Number(rawStatus),
        status: statusLabel(Number(rawStatus)),
        startTime: startTime as bigint,
        endTime: end,
        tokenSupply: tokenSupply as bigint,
        startingPrice: startingPrice as bigint,
        reservePrice: reservePrice as bigint,
        currentPrice: currentPrice as bigint,
        closingTime: closingTime as bigint,
        closingPrice: closingPrice as bigint,
        totalAccepted: totalAccepted as bigint,
        cap: cap as bigint,
        commitments: commitments as bigint,
        walletAccepted: walletAccepted as bigint,
        walletTokens: walletTokens as bigint,
        walletRefund: walletRefund as bigint,
        claimed: claimed as boolean,
        refundClaimed: refundClaimed as boolean,
        proceeds: (proceeds as bigint) - (proceedsWithdrawn as bigint),
        refundLiability: refundLiability as bigint,
        finalPrice: finalPrice as bigint,
        finalTime: finalTime as bigint,
      };
    }),
  );
}
