export async function watchAuctionToken(provider, chainId, token) {
  if (!provider?.request) return "unsupported";

  try {
    const activeChain = await provider.request({ method: "eth_chainId" });
    if (Number(activeChain) !== chainId) return "wrong-network";

    const accepted = await provider.request({
      method: "wallet_watchAsset",
      params: {
        type: "ERC20",
        options: {
          address: token.token,
          symbol: token.symbol,
          decimals: token.decimals,
        },
      },
    });
    return accepted === true ? "accepted" : "dismissed";
  } catch (error) {
    switch (error?.code) {
      case 4001:
        return "dismissed";
      case 4200:
      case -32601:
        return "unsupported";
      case -32002:
        return "pending";
      default:
        return "failed";
    }
  }
}
