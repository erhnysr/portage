import Link from "next/link";
import CreateArenaForm from "@/components/create/CreateArenaForm";

export default function CreatePage() {
  return (
    <div className="max-w-3xl mx-auto px-6 py-10">
      <div className="mb-8 font-mono text-xs uppercase tracking-[0.15em] text-text/45">
        <Link href="/arenas" className="hover:text-accent transition-colors">
          Arenas
        </Link>
        <span className="mx-2">/</span>
        <span className="text-text/70">Create</span>
      </div>

      <p className="font-mono text-xs uppercase tracking-[0.2em] text-accent mb-3">Round I of IV</p>
      <h1 className="font-display text-5xl font-semibold tracking-tight text-text mb-3">
        Open an arena.
      </h1>
      <p className="text-text/60 text-lg mb-10 max-w-xl">
        State the question, fund the pot, and set the windows. The factory deploys your arena
        contract in a single transaction.
      </p>

      <CreateArenaForm />
    </div>
  );
}
