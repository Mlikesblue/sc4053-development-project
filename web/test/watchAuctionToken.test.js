import assert from "node:assert/strict";
import test from "node:test";

import { watchAuctionToken } from "../src/watchAuctionToken.js";

const anvilToken = {
  token: "0x8Ff3801288a85ea261E4277d44E1131Ea736F77B",
  symbol: "CTN",
  decimals: 18,
};

function walletOn(chain, watch = () => true) {
  const requests = [];
  const provider = {
    async request(request) {
      requests.push(request);
      if (request.method === "eth_chainId") return chain;
      assert.equal(request.method, "wallet_watchAsset");
      return watch();
    },
  };
  return { provider, requests };
}

test("uses the selected auction token on Anvil and Sepolia without sending a transaction", async () => {
  const sepoliaToken = {
    token: "0x1234567890123456789012345678901234567890",
    symbol: "TEST",
    decimals: 6,
  };
  for (const [chain, chainId, token] of [
    ["0x7a69", 31337, anvilToken],
    ["0xaa36a7", 11155111, sepoliaToken],
  ]) {
    const { provider, requests } = walletOn(chain);
    assert.equal(await watchAuctionToken(provider, chainId, token), "accepted");
    assert.deepEqual(requests, [
      { method: "eth_chainId" },
      {
        method: "wallet_watchAsset",
        params: {
          type: "ERC20",
          options: { address: token.token, symbol: token.symbol, decimals: token.decimals },
        },
      },
    ]);
  }
});

test("blocks the import request when the wallet is on the wrong chain", async () => {
  const { provider, requests } = walletOn("0xaa36a7");
  assert.equal(await watchAuctionToken(provider, 31337, anvilToken), "wrong-network");
  assert.deepEqual(requests, [{ method: "eth_chainId" }]);
});

test("handles a declined or unsupported wallet request", async () => {
  assert.equal(await watchAuctionToken(undefined, 31337, anvilToken), "unsupported");
  const declined = walletOn("0x7a69", () => false);
  assert.equal(await watchAuctionToken(declined.provider, 31337, anvilToken), "dismissed");

  for (const [code, expected] of [[4001, "dismissed"], [4200, "unsupported"], [-32601, "unsupported"], [-32002, "pending"], [-32602, "failed"]]) {
    const { provider } = walletOn("0x7a69", () => {
      throw Object.assign(new Error("Wallet RPC error"), { code });
    });
    assert.equal(await watchAuctionToken(provider, 31337, anvilToken), expected);
  }
});
