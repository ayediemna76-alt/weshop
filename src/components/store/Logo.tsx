import { Link } from "@tanstack/react-router";
import { cn } from "@/lib/utils";

export function Logo({ className, inverted = false }: { className?: string; inverted?: boolean }) {
  return (
    <Link
      to="/"
      className={cn("group inline-flex items-center gap-2", className)}
      aria-label="weshop"
    >
      <span
        className={cn(
          "grid h-8 w-8 place-items-center rounded-lg font-display text-sm font-bold",
          inverted
            ? "bg-sidebar-primary text-sidebar-primary-foreground"
            : "bg-primary text-primary-foreground",
        )}
      >
        w
      </span>
      <span
        className={cn(
          "font-display text-xl font-semibold tracking-tight",
          inverted ? "text-sidebar-accent-foreground" : "text-foreground",
        )}
      >
        we<span className={inverted ? "text-sidebar-primary" : "text-primary"}>shop</span>
      </span>
    </Link>
  );
}
