import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createWalletClient,
  custom,
  formatEther,
  formatUnits,
  isAddress,
  parseEther,
  type Address,
  type Hash,
  type PublicClient,
} from "viem";

import {
  activityEvents,
  anvil,
  auctionAbi,
  call,
  factoryAbi,
  factoryAddressFor,
  networks,
  publicClientFor,
  readAuctions,
  type AuctionView,
  type NetworkKey,
} from "../chain";
import { curvePrice } from "../priceCurve.js";
import { watchAuctionToken } from "../watchAuctionToken.js";

type ActivityStatus = "awaiting signature" | "pending" | "confirmed" | "rejected" | "reverted";
interface Activity {
  id: string;
  action: string;
  amount: string;
  timestamp: number;
  status: ActivityStatus;
  hash?: Hash;
}
interface NetworkHistory {
  blockCursor: string;
  activities: Activity[];
}

const CURVE_NAMES = ["Linear", "Quadratic slow-initial", "Quadratic fast-initial"];
// Alchemy's free Sepolia tier caps eth_getLogs at a 10-block range per call.
// Anvil has no limit; a small chunk size just means more (still fast) local calls.
// Keeping one conservative value keeps the code identical on both chains.
const MAX_LOG_BLOCK_RANGE = 10n;

function historyKey(network: NetworkKey, auction: Address, account: Address) {
  return `dutch-auction/activity/v1/${network}/${auction.toLowerCase()}/${account.toLowerCase()}`;
}

function readHistory(key: string): NetworkHistory {
  try {
    const parsed = JSON.parse(localStorage.getItem(key) ?? "");
    return {
      blockCursor: String(parsed.blockCursor ?? "0"),
      activities: Array.isArray(parsed.activities) ? parsed.activities : [],
    };
  } catch {
    return { blockCursor: "0", activities: [] };
  }
}

function persistHistory(key: string, history: NetworkHistory) {
  localStorage.setItem(key, JSON.stringify(history));
}

function statusClass(status: string) {
  return status.toLowerCase().replaceAll(" ", "-");
}

function formatEth(value: bigint, digits = 5) {
  const [whole, fraction = ""] = formatEther(value).split(".");
  const places = value > 0n && value < 10n ** 13n ? 18 : digits;
  const short = fraction.slice(0, places).replace(/0+$/, "");
  return short ? `${whole}.${short}` : whole;
}

function shortAddress(value?: string) {
  return value ? `${value.slice(0, 6)}…${value.slice(-4)}` : "Connect wallet";
}

function useChainTime() {
  const [anchor, setAnchor] = useState({ timestamp: 0n, monotonicAt: performance.now() });
  const [now, setNow] = useState(0n);
  useEffect(() => {
    const update = () => {
      const elapsed = BigInt(Math.floor((performance.now() - anchor.monotonicAt) / 1_000));
      setNow(anchor.timestamp + elapsed);
    };
    update();
    const timer = window.setInterval(update, 1_000);
    return () => window.clearInterval(timer);
  }, [anchor]);
  const observe = useCallback((timestamp: bigint) => {
    setAnchor((current) => {
      const estimated = current.timestamp +
        BigInt(Math.floor((performance.now() - current.monotonicAt) / 1_000));
      return timestamp > estimated
        ? { timestamp, monotonicAt: performance.now() }
        : current;
    });
  }, []);
  return { now, observe };
}

function PriceCurve({ auction, now }: { auction: AuctionView; now: bigint }) {
  const cancelled = auction.rawStatus === 5;
  const closed = auction.rawStatus === 3 || auction.rawStatus === 4;
  const stopAt = closed
    ? auction.finalTime !== 0n ? auction.finalTime : auction.closingTime
    : cancelled
      ? auction.startTime
      : now < auction.endTime ? now : auction.endTime;
  const elapsed = stopAt <= auction.startTime
    ? 0n
    : stopAt - auction.startTime > 1_200n
      ? 1_200n
      : stopAt - auction.startTime;
  const markerPrice = closed
    ? auction.finalPrice !== 0n ? auction.finalPrice : auction.closingPrice
    : curvePrice(auction.startingPrice, auction.reservePrice, auction.curve, elapsed);
  const xAt = (seconds: number) => 24 + seconds / 1_200 * 712;
  const yAt = (price: bigint) => {
    const spread = auction.startingPrice - auction.reservePrice;
    const progress = spread === 0n
      ? 1
      : Number((auction.startingPrice - price) * 1_000_000n / spread) / 1_000_000;
    return 22 + Math.max(0, Math.min(1, progress)) * 154;
  };
  const points = Array.from({ length: 41 }, (_, index) => {
    const seconds = Math.round(index * 30);
    return `${xAt(seconds)},${yAt(curvePrice(auction.startingPrice, auction.reservePrice, auction.curve, BigInt(seconds)))}`;
  }).join(" ");

  return (
    <div className="curve-frame">
      <svg viewBox="0 0 760 202" role="img" aria-label={`${CURVE_NAMES[auction.curve]} token price curve`}>
        <defs>
          <linearGradient id="curveFill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="#72e6c0" stopOpacity=".18" />
            <stop offset="100%" stopColor="#72e6c0" stopOpacity="0" />
          </linearGradient>
        </defs>
        {[22, 99, 176].map((y) => <line key={y} x1="24" x2="736" y1={y} y2={y} className="grid-line" />)}
        <polygon points={`24,22 ${points} 736,176 24,176`} fill="url(#curveFill)" />
        <polyline points={points} className="curve-line" />
        <line x1={xAt(Number(elapsed))} x2={xAt(Number(elapsed))} y1="20" y2="178" className="curve-marker-line" />
        <circle cx={xAt(Number(elapsed))} cy={yAt(markerPrice)} r="7" className="curve-marker" />
        <text x="24" y="196" className="axis-label">0:00</text>
        <text x="380" y="196" textAnchor="middle" className="axis-label">10:00</text>
        <text x="736" y="196" textAnchor="end" className="axis-label">20:00</text>
      </svg>
      <div className="curve-footer">
        <span><i className="legend-dot" />Live price marker</span>
        <span>{closed ? "Price frozen at close" : cancelled ? "Cancelled before bidding" : "Updates locally each second"}</span>
      </div>
    </div>
  );
}

function networkDetails(network: NetworkKey) {
  return network === "anvil" ? "Anvil · chain 31337" : "Sepolia · chain 11155111";
}

function explorerUrl(network: NetworkKey, hash: Hash) {
  return network === "sepolia" ? `https://sepolia.etherscan.io/tx/${hash}` : undefined;
}

async function fetchOnchainActivity(
  client: PublicClient,
  auction: Address,
  account: Address,
  deploymentBlock: bigint,
  key: string,
) {
  const history = readHistory(key);
  const toBlock = await client.getBlockNumber();
  let fromBlock = BigInt(history.blockCursor);
  if (fromBlock < deploymentBlock) fromBlock = deploymentBlock;
  const collected: Activity[] = [];

  while (fromBlock <= toBlock) {
    const lastBlock = fromBlock + MAX_LOG_BLOCK_RANGE - 1n < toBlock
      ? fromBlock + MAX_LOG_BLOCK_RANGE - 1n
      : toBlock;
    const [bids, claims, refunds, proceeds] = await Promise.all([
      client.getLogs({ address: auction, event: activityEvents.bid, args: { bidder: account }, fromBlock, toBlock: lastBlock }),
      client.getLogs({ address: auction, event: activityEvents.claim, args: { bidder: account }, fromBlock, toBlock: lastBlock }),
      client.getLogs({ address: auction, event: activityEvents.refund, args: { bidder: account }, fromBlock, toBlock: lastBlock }),
      client.getLogs({ address: auction, event: activityEvents.proceeds, args: { admin: account }, fromBlock, toBlock: lastBlock }),
    ]);
    for (const log of bids) {
      const args = log.args;
      const excess = args.excessWei ?? 0n;
      collected.push({
        id: `chain:${log.transactionHash}:${log.logIndex}`,
        action: "Bid",
        amount: excess
          ? `${formatEth(args.acceptedWei ?? 0n)} ETH accepted · ${formatEth(excess)} ETH refundable at settlement`
          : `${formatEth(args.acceptedWei ?? 0n)} ETH accepted`,
        timestamp: Number(args.timestamp ?? 0n),
        status: "confirmed",
        hash: log.transactionHash,
      });
    }
    for (const log of claims) {
      const [block] = log.blockNumber ? await Promise.all([client.getBlock({ blockNumber: log.blockNumber })]) : [];
      collected.push({
        id: `chain:${log.transactionHash}:${log.logIndex}`,
        action: "Claim",
        amount: `${formatUnits(log.args.tokenAmount ?? 0n, 18)} tokens · ${formatEth(log.args.refundWei ?? 0n)} ETH`,
        timestamp: Number(block?.timestamp ?? 0n),
        status: "confirmed",
        hash: log.transactionHash,
      });
    }
    for (const log of refunds) {
      const block = log.blockNumber ? await client.getBlock({ blockNumber: log.blockNumber }) : undefined;
      collected.push({
        id: `chain:${log.transactionHash}:${log.logIndex}`,
        action: "Refund withdrawal",
        amount: `${formatEth(log.args.amountWei ?? 0n)} ETH → ${shortAddress(log.args.recipient)}`,
        timestamp: Number(block?.timestamp ?? 0n),
        status: "confirmed",
        hash: log.transactionHash,
      });
    }
    for (const log of proceeds) {
      const block = log.blockNumber ? await client.getBlock({ blockNumber: log.blockNumber }) : undefined;
      collected.push({
        id: `chain:${log.transactionHash}:${log.logIndex}`,
        action: "Proceeds withdrawal",
        amount: `${formatEth(log.args.amountWei ?? 0n)} ETH`,
        timestamp: Number(block?.timestamp ?? 0n),
        status: "confirmed",
        hash: log.transactionHash,
      });
    }
    fromBlock = lastBlock + 1n;
  }

  const unique = new Map<string, Activity>();
  const confirmedHashes = new Set(collected.flatMap((item) => item.hash ? [item.hash] : []));
  for (const item of history.activities) {
    if (!item.hash || !confirmedHashes.has(item.hash)) unique.set(item.id, item);
  }
  for (const item of collected) unique.set(item.id, item);
  const activities = [...unique.values()].sort((a, b) => b.timestamp - a.timestamp);
  const nextHistory = {
    blockCursor: toBlock.toString(),
    activities: activities.slice(0, 100),
  };
  persistHistory(key, nextHistory);
  return nextHistory.activities;
}

export function App() {
  const chainClock = useChainTime();
  const now = chainClock.now;
  const [network, setNetwork] = useState<NetworkKey>("anvil");
  const [account, setAccount] = useState<Address>();
  const [walletChainId, setWalletChainId] = useState<number>();
  const [auctionSnapshot, setAuctionSnapshot] = useState<{
    network: NetworkKey;
    account?: Address;
    items: AuctionView[];
  }>();
  const [selectedAddress, setSelectedAddress] = useState<Address>();
  const [admin, setAdmin] = useState<Address>();
  const [activity, setActivity] = useState<Activity[]>([]);
  const [notice, setNotice] = useState("");
  const [loadError, setLoadError] = useState("");
  const [working, setWorking] = useState(false);
  const [watchingToken, setWatchingToken] = useState(false);
  const [bidAmount, setBidAmount] = useState("");
  const [newTokenName, setNewTokenName] = useState("");
  const [newTokenSymbol, setNewTokenSymbol] = useState("");
  const [newSupply, setNewSupply] = useState("");
  const [newStartingPrice, setNewStartingPrice] = useState("0.01");
  const [newReservePrice, setNewReservePrice] = useState("0.004");
  const [newCurve, setNewCurve] = useState("0");
  const [newStartDate, setNewStartDate] = useState("");

  const factoryAddress = factoryAddressFor(network);
  const publicClient = useMemo(() => publicClientFor(network), [network]);
  const auctions = auctionSnapshot?.items ?? [];
  const auction = auctions.find((item) => item.address === selectedAddress) ?? auctions[0];
  const walletConnected = Boolean(account);
  const connectedToSelectedNetwork = walletChainId === networks[network].id;
  const isAdmin = Boolean(admin && account && admin.toLowerCase() === account.toLowerCase());
  const closeTime = auction && auction.finalTime !== 0n ? auction.finalTime : auction?.closingTime ?? 0n;
  const activityStorageKey = account && auction
    ? historyKey(network, auction.address, account)
    : undefined;
  const openAuctions = auctions.filter((item) => item.status !== "Finalized" && item.status !== "Cancelled");

  const addLocalActivity = useCallback((
    key: string,
    entry: Omit<Activity, "id" | "timestamp"> & { timestamp?: number; id?: string },
  ) => {
    const old = readHistory(key);
    const next: Activity = {
      id: entry.id ?? `local:${crypto.randomUUID()}`,
      action: entry.action,
      amount: entry.amount,
      timestamp: entry.timestamp ?? Math.floor(Date.now() / 1_000),
      status: entry.status,
      hash: entry.hash,
    };
    const activities = [next, ...old.activities.filter((item) => item.id !== next.id)].slice(0, 100);
    persistHistory(key, { ...old, activities });
    setActivity(activities);
    return next.id;
  }, []);

  const updateLocalActivity = useCallback((key: string, id: string, values: Partial<Activity>) => {
    const old = readHistory(key);
    const activities = old.activities.map((item) => item.id === id ? { ...item, ...values } : item);
    persistHistory(key, { ...old, activities });
    setActivity(activities);
  }, []);

  const refresh = useCallback(async () => {
    if (!publicClient || !factoryAddress) {
      setAuctionSnapshot(undefined);
      setAdmin(undefined);
      setLoadError("");
      return;
    }
    try {
      const [items, owner, latestBlock] = await Promise.all([
        readAuctions(publicClient, factoryAddress, account),
        call(publicClient, factoryAddress, factoryAbi, "owner"),
        publicClient.getBlock(),
      ]);
      chainClock.observe(latestBlock.timestamp);
      setAuctionSnapshot({ network, account, items });
      setAdmin(owner as Address);
      setLoadError("");
      if (selectedAddress && !items.some((item) => item.address === selectedAddress)) {
        setSelectedAddress(undefined);
      }
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : "Could not load auctions from this network.");
    }
  }, [account, chainClock.observe, factoryAddress, network, publicClient, selectedAddress]);

  useEffect(() => {
    let active = true;
    async function loadWallet() {
      const ethereum = window.ethereum;
      if (!ethereum) return;
      try {
        const [accounts, chainId] = await Promise.all([
          ethereum.request({ method: "eth_accounts" }),
          ethereum.request({ method: "eth_chainId" }),
        ]);
        if (!active) return;
        const connected = accounts as string[];
        setAccount(connected[0] as Address | undefined);
        setWalletChainId(Number(BigInt(chainId as string)));
      } catch {
        setAccount(undefined);
      }
    }
    void loadWallet();
    window.ethereum?.on?.("accountsChanged", (accounts: string[]) => {
      setAccount(accounts[0] as Address | undefined);
    });
    window.ethereum?.on?.("chainChanged", (chainId: string) => {
      setWalletChainId(Number(BigInt(chainId)));
    });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 4_000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  useEffect(() => {
    if (!account || !activityStorageKey) {
      setActivity([]);
      return;
    }
    setActivity(readHistory(activityStorageKey).activities);
    if (!publicClient || !auction) return;
    const deploymentBlock = BigInt(
      network === "anvil"
        ? import.meta.env.VITE_ANVIL_DEPLOYMENT_BLOCK || "0"
        : import.meta.env.VITE_SEPOLIA_DEPLOYMENT_BLOCK || "0",
    );
    let active = true;
    void fetchOnchainActivity(publicClient, auction.address, account, deploymentBlock, activityStorageKey)
      .then((items) => { if (active) setActivity(items); })
      .catch((error) => { if (active) setLoadError(error instanceof Error ? error.message : "Activity log is unavailable."); });
    return () => { active = false; };
  }, [account, activityStorageKey, auction, network, publicClient]);

  async function connectWallet() {
    if (!window.ethereum) {
      setNotice("Install a browser wallet such as MetaMask to bid or manage auctions.");
      return;
    }
    try {
      const accounts = await window.ethereum.request({ method: "eth_requestAccounts" }) as string[];
      const chainId = await window.ethereum.request({ method: "eth_chainId" }) as string;
      setAccount(accounts[0] as Address);
      setWalletChainId(Number(BigInt(chainId)));
      setNotice("Wallet connected.");
    } catch (error) {
      setNotice(isRejected(error) ? "Wallet connection was rejected." : errorMessage(error));
    }
  }

  async function switchWalletNetwork() {
    if (!window.ethereum) return void setNotice("Connect a browser wallet first.");
    const chain = networks[network];
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: `0x${chain.id.toString(16)}` }],
      });
      setWalletChainId(chain.id);
      setNotice(`Wallet switched to ${chain.name}.`);
    } catch (error) {
      if (typeof error === "object" && error !== null && "code" in error && (error as { code: number }).code === 4902) {
        try {
          const rpcUrl = network === "anvil"
            ? "http://127.0.0.1:8545"
            : import.meta.env.VITE_SEPOLIA_RPC_URL || "https://rpc.sepolia.org";
          await window.ethereum.request({
            method: "wallet_addEthereumChain",
            params: [{
              chainId: `0x${chain.id.toString(16)}`,
              chainName: chain.name,
              nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
              rpcUrls: [rpcUrl],
              ...(network === "sepolia" ? { blockExplorerUrls: ["https://sepolia.etherscan.io"] } : {}),
            }],
          });
          setWalletChainId(chain.id);
          setNotice(`${chain.name} added to your wallet.`);
        } catch (addError) {
          setNotice(errorMessage(addError));
        }
      } else {
        setNotice(isRejected(error) ? "Network change was rejected." : errorMessage(error));
      }
    }
  }

  async function addTokenToMetaMask(item: AuctionView) {
    setWatchingToken(true);
    setNotice(`Check your wallet to add ${item.symbol}.`);
    try {
      const result = await watchAuctionToken(window.ethereum, networks[network].id, item);
      const manualImport = `Import ${item.symbol} manually using ${item.token}.`;
      setNotice({
        accepted: `Check your wallet’s Tokens list for ${item.symbol}.`,
        dismissed: "Token import was dismissed.",
        "wrong-network": `Switch your wallet to ${networkDetails(network)} to add ${item.symbol}.`,
        unsupported: `Your wallet does not support adding tokens from this page. ${manualImport}`,
        pending: "A wallet request is already open. Check your wallet.",
        failed: `Your wallet could not add the token. ${manualImport}`,
      }[result]);
    } finally {
      setWatchingToken(false);
    }
  }

  async function sendAction(
    label: string,
    amount: string,
    contractAddress: Address,
    abi: any,
    functionName: string,
    args: unknown[],
    value = 0n,
  ) {
    if (!account || !window.ethereum) return void setNotice("Connect your wallet to submit this transaction.");
    if (!connectedToSelectedNetwork) return void setNotice("Switch your wallet to the selected network first.");
    const key = historyKey(network, contractAddress, account);
    const entryId = addLocalActivity(key, {
      action: label,
      amount,
      status: "awaiting signature",
    });
    setWorking(true);
    setNotice(`Waiting for wallet signature · ${label}`);
    try {
      const wallet = createWalletClient({
        account,
        chain: networks[network] as typeof anvil,
        transport: custom(window.ethereum),
      });
      const hash = await wallet.writeContract({
        address: contractAddress,
        abi,
        functionName,
        args,
        value,
      } as any);
      updateLocalActivity(key, entryId, { status: "pending", hash });
      setNotice(`Transaction pending · ${shortAddress(hash)}`);
      const receipt = await publicClient!.waitForTransactionReceipt({ hash });
      const status: ActivityStatus = receipt.status === "success" ? "confirmed" : "reverted";
      updateLocalActivity(key, entryId, { status, hash });
      setNotice(status === "confirmed" ? `${label} confirmed.` : `${label} reverted on chain.`);
      await refresh();
    } catch (error) {
      const rejected = isRejected(error);
      updateLocalActivity(key, entryId, { status: rejected ? "rejected" : "reverted" });
      setNotice(rejected ? "Wallet request rejected." : errorMessage(error));
    } finally {
      setWorking(false);
    }
  }

  async function createAuction() {
    if (!factoryAddress) return void setNotice("Set the factory address in the local .env file first.");
    if (!newTokenName.trim() || !newTokenSymbol.trim() || !/^\d+$/.test(newSupply) || BigInt(newSupply || "0") === 0n) {
      return void setNotice("Enter the token name, symbol, and a positive whole-token supply.");
    }
    let startTimestamp = 0n;
    if (newStartDate) {
      startTimestamp = BigInt(Math.floor(new Date(newStartDate).getTime() / 1_000));
      if (startTimestamp <= now) return void setNotice("Choose a future scheduled start.");
    }
    let startingPrice: bigint;
    let reservePrice: bigint;
    try {
      startingPrice = parseEther(newStartingPrice);
      reservePrice = parseEther(newReservePrice);
    } catch {
      return void setNotice("Enter valid ETH prices.");
    }
    if (startingPrice <= reservePrice || reservePrice <= 0n) {
      return void setNotice("Starting price must exceed a positive reserve price.");
    }
    const input = {
      tokenName: newTokenName.trim(),
      tokenSymbol: newTokenSymbol.trim(),
      wholeTokenSupply: BigInt(newSupply),
      startingPriceWeiPerToken: startingPrice,
      reservePriceWeiPerToken: reservePrice,
      curve: Number(newCurve),
      scheduledStartTime: startTimestamp,
    };
    await sendAction(
      "Create auction",
      `${input.wholeTokenSupply} tokens · ${formatEth(startingPrice)} ETH start · ${formatEth(reservePrice)} ETH reserve`,
      factoryAddress,
      factoryAbi,
      "createAuction",
      [input],
    );
  }

  function handleBid() {
    if (!auction) return;
    try {
      const value = parseEther(bidAmount);
      if (value <= 0n) throw new Error("Enter an ETH amount greater than zero.");
      void sendAction("Bid", `${formatEth(value)} ETH`, auction.address, auctionAbi, "bid", [], value);
      setBidAmount("");
    } catch (error) {
      setNotice(errorMessage(error));
    }
  }

  function isRejected(error: unknown) {
    return typeof error === "object" && error !== null && "code" in error && (error as { code: number }).code === 4001;
  }

  function errorMessage(error: unknown) {
    if (error instanceof Error) return error.message.replace(/^.*?execution reverted: /i, "");
    return "The wallet request could not be completed.";
  }

  const settlementRecorded = Boolean(auction && auction.rawStatus >= 4);
  const canAddClaimedToken = account && auction?.claimed && auction.walletTokens > 0n
    && auctionSnapshot?.network === network && auctionSnapshot.account === account;
  const claimReady = Boolean(auction && (
    (auction.rawStatus === 3 && auction.walletAccepted !== 0n) ||
    (settlementRecorded && (
      (auction.walletTokens !== 0n && !auction.claimed) ||
      (auction.walletRefund !== 0n && !auction.refundClaimed)
    ))
  ));
  const isOpen = auction?.status === "Open";
  const deploymentReady = Boolean(publicClient && factoryAddress);

  return (
    <main className="app-shell">
      <header className="topbar">
        <a className="brand" href="#" aria-label="Drop home"><span className="brand-mark">d</span><span>drop</span></a>
        <nav className="topnav" aria-label="Main navigation">
          <a className="nav-current" href="#auctions">Auctions</a>
          <a href="#how-it-works">How it works</a>
        </nav>
        <div className="top-actions">
          <label className="network-select">
            <span className="network-indicator" />
            <select value={network} onChange={(event) => setNetwork(event.target.value as NetworkKey)} aria-label="Read network">
              <option value="anvil">Anvil local</option>
              <option value="sepolia">Sepolia</option>
            </select>
          </label>
          {walletConnected ? (
            <button className="wallet-button connected" onClick={() => setNotice(`Connected wallet ${account} · ${networkDetails(network)}`)}>
              <span className="wallet-dot" />{shortAddress(account)}
            </button>
          ) : (
            <button className="wallet-button" onClick={() => void connectWallet()}>Connect wallet</button>
          )}
        </div>
      </header>

      <section className="hero" id="auctions">
        <div className="hero-copy">
          <div className="eyebrow"><span className="eyebrow-line" />TOKEN LAUNCHES, WITH THE PRICE OUT IN THE OPEN</div>
          <h1>A fair start<br /><span>for every token.</span></h1>
          <p>Watch the price fall. Commit ETH when it feels right. Every winner pays the same final price.</p>
          <a href="#auction-list" className="text-link">Explore auctions <span>↘</span></a>
        </div>
        <div className="hero-visual" aria-hidden="true">
          <div className="orbital orbital-a" /><div className="orbital orbital-b" />
          <div className="hero-token"><span className="token-core">d</span><span className="token-shine" /></div>
          <div className="float-label float-left">PRICE DISCOVERY <span>ON CHAIN</span></div>
          <div className="float-label float-right"><span className="signal-dot" /> LIVE CURVE</div>
          <div className="hero-spark spark-a">✦</div><div className="hero-spark spark-b">✧</div>
        </div>
      </section>

      <section className="auction-section">
        <div className="section-heading" id="auction-list">
          <div><div className="eyebrow"><span className="eyebrow-line" />THE AUCTION FLOOR</div><h2>Auctions</h2></div>
          <span className="section-count">{openAuctions.length.toString().padStart(2, "0")} ACTIVE</span>
        </div>

        {!deploymentReady ? (
          <div className="empty-state config-state">
            <span className="empty-orbit">◌</span>
            <h3>Connect the auction factory</h3>
            <p>Set a deployed factory address and RPC URL in <code>web/.env.local</code> to browse on {networkDetails(network)}.</p>
          </div>
        ) : loadError ? (
          <div className="empty-state error-state"><h3>Network data is unavailable</h3><p>{loadError}</p></div>
        ) : auctions.length === 0 ? (
          <div className="empty-state"><span className="empty-orbit">◌</span><h3>No auctions yet</h3><p>New launches will appear here when they’re created.</p></div>
        ) : (
          <div className="auction-layout">
            <aside className="auction-list" aria-label="Auctions">
              {auctions.map((item, index) => (
                <button
                  className={`auction-list-item ${auction?.address === item.address ? "selected" : ""}`}
                  key={item.address}
                  onClick={() => setSelectedAddress(item.address)}
                >
                  <span className="list-icon">{item.symbol.slice(0, 1).toUpperCase() || "T"}</span>
                  <span className="list-text"><strong>{item.name}</strong><small>{item.symbol} · #{String(index + 1).padStart(3, "0")}</small></span>
                  <span className={`status-pill status-${statusClass(item.status)}`}><i />{item.status}</span>
                </button>
              ))}
            </aside>
            {auction && (
              <section className="auction-card">
                <div className="auction-card-header">
                  <div className="token-title">
                    <div className="token-avatar">{auction.symbol.slice(0, 1).toUpperCase()}</div>
                    <div><h3>{auction.name}</h3><span>{auction.symbol} <span className="subtle-dot">·</span> {formatUnits(auction.tokenSupply ?? 0n, 18)} tokens</span></div>
                  </div>
                  <span className={`status-pill status-${statusClass(auction.status)}`}><i />{auction.status}</span>
                </div>
                <div className="market-strip">
                  <div className="market-price"><span>CURRENT PRICE</span><strong>{formatEth(auction.currentPrice)} <small>ETH</small></strong></div>
                  <div className="market-item"><span>STARTING PRICE</span><strong>{formatEth(auction.startingPrice)} ETH</strong></div>
                  <div className="market-item"><span>RESERVE PRICE</span><strong>{formatEth(auction.reservePrice)} ETH</strong></div>
                  <div className="market-item"><span>AUCTION CLOCK</span><strong>{countdown(auction, now)}</strong></div>
                </div>

                <div className="chart-heading"><div><span>PRICE DECAY</span><strong>{CURVE_NAMES[auction.curve]}</strong></div><span className="chart-duration"><i className="signal-dot" />20 MIN MAX</span></div>
                <PriceCurve auction={auction} now={now} />

                <div className="auction-stats">
                  <div><span>TOTAL ACCEPTED</span><strong>{formatEth(auction.totalAccepted)} ETH</strong></div>
                  <div><span>YOUR ACCEPTED ETH</span><strong>{formatEth(auction.walletAccepted)} ETH</strong></div>
                  <div><span>COMMITMENTS</span><strong>{auction.commitments.toString()} <small>/ {auction.cap.toString()}</small></strong></div>
                  <div><span>CLOSING PRICE</span><strong>{auction.rawStatus >= 3 ? `${formatEth(auction.finalPrice || auction.closingPrice)} ETH` : "—"}</strong></div>
                </div>

                {walletConnected && !connectedToSelectedNetwork && (
                  <div className="notice network-notice"><span>Switch MetaMask to {networkDetails(network)} to use this auction.</span><button onClick={() => void switchWalletNetwork()}>Switch network ↗</button></div>
                )}
                {isOpen && walletConnected && connectedToSelectedNetwork && (
                  <div className="action-panel">
                    <label className="field-label" htmlFor="bid-amount">COMMIT ETH</label>
                    <div className="bid-row">
                      <div className="input-wrap"><input id="bid-amount" type="number" min="0" step="any" placeholder="0.00" value={bidAmount} onChange={(event) => setBidAmount(event.target.value)} /><span>ETH</span></div>
                      <button className="primary-button" disabled={working || !bidAmount} onClick={handleBid}>Commit bid <span>↗</span></button>
                    </div>
                    <p>Commitments can’t be withdrawn. Your final price is set when the auction closes.</p>
                  </div>
                )}
                {auction.status === "Scheduled" && <div className="notice muted-notice">Bidding opens at the scheduled start time.</div>}
                {auction.status === "Capacity reached" && <div className="notice muted-notice">Commitment capacity reached. Existing bids remain active until sellout or the deadline.</div>}
                {auction.status === "Closed" && <div className="notice muted-notice">Auction closed at {new Date(Number(closeTime) * 1_000).toLocaleString()} · final price {formatEth(auction.closingPrice)} ETH per token.</div>}

                {walletConnected && auction.walletAccepted !== 0n && (
                  <div className="entitlement-row">
                    <div className="entitlement-values">
                      <span>{settlementRecorded ? "YOUR SETTLEMENT" : "YOUR SETTLEMENT · CALCULATED ON CLAIM"}</span>
                      {settlementRecorded ? (
                        <>
                          <strong>Tokens <i>{auction.walletTokens === 0n ? "none" : auction.claimed ? "claimed" : "outstanding"}</i> · {formatUnits(auction.walletTokens, 18)}</strong>
                          <strong>Refund <i>{auction.walletRefund === 0n ? "none" : auction.refundClaimed ? "withdrawn" : "outstanding"}</i> · {formatEth(auction.walletRefund)} ETH</strong>
                        </>
                      ) : <strong>Claim will finalize the auction and record your token and refund amounts.</strong>}
                    </div>
                    {claimReady && <button className="primary-button claim-button" disabled={working} onClick={() => void sendAction("Claim", settlementRecorded ? `${formatUnits(auction.walletTokens, 18)} tokens · ${formatEth(auction.walletRefund)} ETH` : "Finalize auction and claim settlement", auction.address, auctionAbi, "claim", [])}>Claim tokens + ETH <span>↗</span></button>}
                    {auction.rawStatus >= 3 && auction.walletTokens !== 0n && auction.claimed && <span className="claimed-label">Tokens claimed</span>}
                    {auction.rawStatus >= 3 && auction.walletRefund !== 0n && auction.refundClaimed && <span className="claimed-label">Refund withdrawn</span>}
                  </div>
                )}
                {canAddClaimedToken && (
                  <div className="fallback-row">
                    <span>Show {auction.symbol} in your wallet</span>
                    <button type="button" disabled={watchingToken} onClick={() => void addTokenToMetaMask(auction)}>
                      {watchingToken ? "Check your wallet…" : "Add to MetaMask"}
                    </button>
                  </div>
                )}
                {walletConnected && settlementRecorded && auction.walletTokens !== 0n && !auction.claimed && (
                  <div className="fallback-row"><span>Having trouble with the combined claim?</span><button onClick={() => void sendAction("Token claim", `${formatUnits(auction.walletTokens, 18)} tokens`, auction.address, auctionAbi, "claimTokens", [])}>Claim tokens only</button></div>
                )}
                {walletConnected && settlementRecorded && auction.walletRefund !== 0n && !auction.refundClaimed && (
                  <div className="fallback-row"><span>Need to redirect your ETH refund?</span><button onClick={() => {
                    const destination = window.prompt("Refund recipient address");
                    if (!destination || !isAddress(destination)) return void setNotice("Enter a valid recipient address.");
                    void sendAction("Refund withdrawal", `${formatEth(auction.walletRefund)} ETH → ${shortAddress(destination)}`, auction.address, auctionAbi, "withdrawRefund", [destination]);
                  }}>Choose refund recipient</button></div>
                )}

                {isAdmin && auction.rawStatus === 4 && auction.proceeds > 0n && (
                  <div className="admin-proceeds"><div><span>AVAILABLE PROCEEDS</span><strong>{formatEth(auction.proceeds)} ETH</strong></div><button className="secondary-button" disabled={working} onClick={() => void sendAction("Withdraw proceeds", `${formatEth(auction.proceeds)} ETH`, auction.address, auctionAbi, "withdrawProceeds", [])}>Withdraw proceeds ↗</button></div>
                )}
                {isAdmin && auction.status === "Scheduled" && (
                  <div className="admin-proceeds"><span>Administrator · cancel before bidding opens</span><button className="danger-button" disabled={working} onClick={() => void sendAction("Cancel auction", "Full token escrow burned", auction.address, auctionAbi, "cancel", [])}>Cancel auction</button></div>
                )}
                {activityStorageKey && (
                  <ActivityLog
                    activity={activity}
                    network={network}
                    onRetry={() => {
                      if (!publicClient || !account || !auction) return;
                      const deploymentBlock = BigInt(network === "anvil" ? import.meta.env.VITE_ANVIL_DEPLOYMENT_BLOCK || "0" : import.meta.env.VITE_SEPOLIA_DEPLOYMENT_BLOCK || "0");
                      void fetchOnchainActivity(publicClient, auction.address, account, deploymentBlock, activityStorageKey)
                        .then(setActivity).catch((error) => setLoadError(errorMessage(error)));
                    }}
                  />
                )}
              </section>
            )}
          </div>
        )}
      </section>

      {isAdmin && factoryAddress && (
        <section className="create-section">
          <div className="section-heading"><div><div className="eyebrow"><span className="eyebrow-line" />ISSUER TOOLS</div><h2>Create an auction</h2></div><span className="section-count">ADMIN ONLY</span></div>
          <div className="create-grid">
            <label>Token name<input value={newTokenName} onChange={(event) => setNewTokenName(event.target.value)} placeholder="Example Token" /></label>
            <label>Token symbol<input value={newTokenSymbol} onChange={(event) => setNewTokenSymbol(event.target.value)} placeholder="EXM" /></label>
            <label>Whole-token supply<input type="number" min="1" step="1" value={newSupply} onChange={(event) => setNewSupply(event.target.value)} placeholder="100000" /></label>
            <label>Starting price · ETH/token<input type="number" min="0" step="any" value={newStartingPrice} onChange={(event) => setNewStartingPrice(event.target.value)} /></label>
            <label>Reserve price · ETH/token<input type="number" min="0" step="any" value={newReservePrice} onChange={(event) => setNewReservePrice(event.target.value)} /></label>
            <label>Price curve<select value={newCurve} onChange={(event) => setNewCurve(event.target.value)}>{CURVE_NAMES.map((name, index) => <option key={name} value={index}>{name}</option>)}</select></label>
            <label className="wide-field">Scheduled start · leave blank to start now<input type="datetime-local" value={newStartDate} onChange={(event) => setNewStartDate(event.target.value)} /></label>
            <div className="create-footer"><span>Settings are fixed at creation · duration is 20 minutes maximum.</span><button className="primary-button" disabled={working} onClick={() => void createAuction()}>Create auction <span>↗</span></button></div>
          </div>
        </section>
      )}

      {notice && <div className="toast" role="status" onClick={() => setNotice("")}>{notice}<button aria-label="Dismiss">×</button></div>}

      <footer className="footer" id="how-it-works">
        <a className="brand footer-brand" href="#"><span className="brand-mark">d</span><span>drop</span></a>
        <span>Transparent price discovery, one auction at a time.</span>
        <span>{networkDetails(network)} <i className="signal-dot" /></span>
      </footer>
    </main>
  );
}

function countdown(auction: AuctionView, now: bigint) {
  if (auction.rawStatus === 5) return "Cancelled";
  if (auction.status === "Scheduled") {
    const seconds = auction.startTime > now ? auction.startTime - now : 0n;
    return `Starts in ${formatCountdown(seconds)}`;
  }
  if (auction.rawStatus >= 3) {
    const seconds = auction.finalTime !== 0n ? auction.finalTime : auction.closingTime;
    return `Closed · ${formatCountdown(seconds > now ? seconds - now : 0n)}`;
  }
  return formatCountdown(auction.endTime > now ? auction.endTime - now : 0n);
}

function formatCountdown(seconds: bigint) {
  const value = Number(seconds);
  const minutes = Math.floor(value / 60);
  const remaining = value % 60;
  return `${String(minutes).padStart(2, "0")}:${String(remaining).padStart(2, "0")}`;
}

function ActivityLog({
  activity,
  network,
  onRetry,
}: {
  activity: Activity[];
  network: NetworkKey;
  onRetry: () => void;
}) {
  return (
    <section className="activity-section">
      <div className="activity-heading"><div><span>YOUR ACTIVITY</span><small>Wallet transactions for this auction</small></div><button onClick={onRetry}>Refresh ↻</button></div>
      {activity.length === 0 ? (
        <div className="activity-empty">No activity yet for this wallet.</div>
      ) : (
        <div className="activity-list">
          {activity.map((item) => {
            const link = item.hash ? explorerUrl(network, item.hash) : undefined;
            return (
              <div className="activity-row" key={item.id}>
                <span className="activity-icon">{item.action === "Bid" ? "↘" : item.action.includes("withdraw") ? "↗" : "◇"}</span>
                <div className="activity-copy"><strong>{item.action}</strong><small>{item.amount}</small></div>
                <time>{new Date(item.timestamp * 1_000).toLocaleString()}</time>
                <span className={`activity-status ${statusClass(item.status)}`}>{item.status}</span>
                {link && <a className="activity-link" href={link} target="_blank" rel="noreferrer" aria-label="View transaction">↗</a>}
                {!link && item.hash && <span className="activity-hash">{shortAddress(item.hash)}</span>}
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
