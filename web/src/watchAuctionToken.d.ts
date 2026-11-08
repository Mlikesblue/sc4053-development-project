import type { AuctionView, EthereumProvider } from "./chain";

export function watchAuctionToken(
  provider: EthereumProvider | undefined,
  chainId: number,
  token: Pick<AuctionView, "token" | "symbol" | "decimals">,
): Promise<"accepted" | "dismissed" | "wrong-network" | "unsupported" | "pending" | "failed">;
