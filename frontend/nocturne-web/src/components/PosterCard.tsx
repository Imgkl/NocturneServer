import { useState } from 'react';
import type { ReactNode } from 'react';
import { ArrowUpRight } from 'lucide-react';
import { posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import type { MoodBuckets, Movie } from '../lib/types';

interface PosterCardProps {
  movie: Movie;
  moods: MoodBuckets;
  onOpen: () => void;
  selected?: boolean;
  // The film's page on the Jellyfin web UI, for the hover button.
  jellyfinHref?: string;
}

function Badge({ children, dark }: { children: ReactNode; dark?: boolean }) {
  return (
    <span
      className={cn(
        'inline-flex h-[22px] min-w-0 items-center gap-1 rounded-full px-2 text-[11px] font-semibold tabular-nums leading-none',
        dark ? 'bg-black/60 text-white backdrop-blur-md' : 'bg-white text-ink shadow-[0_1px_3px_rgba(0,0,0,.12)]',
      )}
    >
      {children}
    </span>
  );
}

// X-Cache's image pin, for a poster: the frame with hover chrome, the folder pill top-left, the
// badges along the bottom, a byline under it.
export function PosterCard({ movie, moods, onOpen, selected, jellyfinHref }: PosterCardProps) {
  const [failed, setFailed] = useState(false);
  const moodNames = (movie.tags || []).map((t) => moods[t.slug]?.title || t.title).join(', ');
  return (
    <article
      role="button"
      tabIndex={0}
      aria-label={moodNames ? `${movie.title}: ${moodNames}` : movie.title}
      onClick={onOpen}
      onKeyDown={(e) => {
        if (e.key === 'Enter') onOpen();
      }}
      className="group relative w-full cursor-pointer select-none text-left outline-none"
    >
      <div className={cn('relative aspect-[2/3] overflow-hidden rounded-2xl bg-[#f2f2f2] [transform:translateZ(0)]', selected && 'outline-2 outline-offset-[3px] outline-ink')}>
        {failed ? (
          <div className="grid h-full w-full place-items-center p-4 text-center">
            <span className="text-[15px] font-semibold leading-tight tracking-[-0.015em] text-ink">{movie.title}</span>
          </div>
        ) : (
          <img
            src={posterUrl(movie.jellyfinId, 'medium')}
            alt=""
            loading="lazy"
            decoding="async"
            draggable={false}
            onError={() => setFailed(true)}
            onLoad={(e) => e.currentTarget.classList.add('loaded')}
            className="img-fade h-full w-full object-cover transition-transform duration-[900ms] ease-[cubic-bezier(.2,.75,.2,1)] group-hover:scale-[1.035]"
          />
        )}
        <div className="pointer-events-none absolute inset-0 bg-black/0 transition duration-300 group-hover:bg-black/[.14]" />
        {jellyfinHref && (
          <a
            href={jellyfinHref}
            target="_blank"
            rel="noreferrer"
            onClick={(e) => e.stopPropagation()}
            aria-label="Open in Jellyfin"
            title="Open in Jellyfin"
            className="absolute right-2.5 top-2.5 grid h-8 w-8 translate-y-1 place-items-center rounded-full bg-white text-ink opacity-0 shadow-[0_1px_3px_rgba(0,0,0,.12)] transition duration-200 hover:scale-105 group-hover:translate-y-0 group-hover:opacity-100"
          >
            <ArrowUpRight size={16} strokeWidth={2.2} />
          </a>
        )}
        {movie.needsReview && <span title="Waiting for review" className="pointer-events-none absolute left-2.5 top-2.5 z-[1] h-2.5 w-2.5 rounded-full bg-[#f5a524] ring-2 ring-white" />}
        {movie.played && (
          <div className="pointer-events-none absolute inset-x-2.5 bottom-2.5 flex items-end justify-between gap-2">
            <Badge dark>Watched</Badge>
          </div>
        )}
      </div>
      <div className="px-0.5 pt-2.5">
        <div className="flex min-w-0 items-center gap-2">
          <span className="min-w-0 flex-1 truncate text-[13px] font-semibold leading-none text-ink" title={movie.title}>
            {movie.title}
          </span>
          {movie.year ? <span className="shrink-0 text-[12px] tabular-nums leading-none text-faint">{movie.year}</span> : null}
        </div>
      </div>
    </article>
  );
}
