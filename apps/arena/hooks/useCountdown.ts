"use client";

import { useState, useEffect } from "react";

type CountdownResult = {
  days: number;
  hours: number;
  minutes: number;
  seconds: number;
  expired: boolean;
  label: string; // e.g. "2d 4h 12m"
};

export function useCountdown(deadlineUnix: bigint | number): CountdownResult {
  const target = typeof deadlineUnix === "bigint" ? Number(deadlineUnix) * 1000 : deadlineUnix * 1000;

  const calc = (): CountdownResult => {
    const diff = target - Date.now();
    if (diff <= 0) return { days: 0, hours: 0, minutes: 0, seconds: 0, expired: true, label: "Ended" };

    const s = Math.floor(diff / 1000);
    const days = Math.floor(s / 86400);
    const hours = Math.floor((s % 86400) / 3600);
    const minutes = Math.floor((s % 3600) / 60);
    const seconds = s % 60;

    const parts: string[] = [];
    if (days > 0) parts.push(`${days}d`);
    if (hours > 0) parts.push(`${hours}h`);
    if (minutes > 0 || days === 0) parts.push(`${minutes}m`);
    if (days === 0 && hours === 0) parts.push(`${seconds}s`);

    return { days, hours, minutes, seconds, expired: false, label: parts.join(" ") };
  };

  const [state, setState] = useState<CountdownResult>(calc);

  useEffect(() => {
    if (state.expired) return;
    const id = setInterval(() => {
      const next = calc();
      setState(next);
      if (next.expired) clearInterval(id);
    }, 1000);
    return () => clearInterval(id);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target]);

  return state;
}
