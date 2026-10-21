import { useState } from 'react';
import { posterUrl } from '../lib/api';
import { cn } from '../lib/cn';
import type { MoodBuckets, Movie } from '../lib/types';

interface PosterCardProps {
  movie: Movie;
  moods: MoodBuckets;
  onOpen: () => void;
  selected?: boolean;
}

// A 2:3 poster in a rounded frame with floating pills: the first mood, Review, Watched.
export function PosterCard({ movie, moods, onOpen, selected }: PosterCardProps) {
  const [failed, setFailed] = useState(false);
  const first = movie.tags?.[0];
  const more = (movie.tags?.length ?? 0) - 1;
  return (
    <button type="button" onClick={onOpen} className="group block w-full text-left cursor-pointer" aria-label={`Open ${movie.title}`}>
      <div
        className={cn(
          'relative aspect-[2/3] w-full overflow-hidden rounded-2xl bg-canvas shadow-[0_0_0_1px_rgba(0,0,0,.05)] transition duration-300 ease-[cubic-bezier(.2,.75,.2,1)] group-hover:-translate-y-[3px] group-hover:shadow-[0_0_0_1px_rgba(0,0,0,.06),0_18px_40px_-18px_rgba(0,0,0,.35)]',
          selected && 'ring-2 ring-ink ring-offset-2',
        )}
      >
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
            className="img-fade h-full w-full object-cover"
          />
        )}
        {(first || movie.needsReview) && (
          <div className="absolute left-2 top-2 flex flex-wrap gap-1">
            {first && (
              <span className="inline-flex h-6 items-center gap-1 rounded-full bg-white px-2.5 text-[11px] font-semibold text-ink shadow-[0_1px_3px_rgba(0,0,0,.18)]">
                {moods[first.slug]?.title || first.title}
                {more > 0 && <span className="text-faint">+{more}</span>}
              </span>
            )}
            {movie.needsReview && <span className="inline-flex h-6 items-center rounded-full bg-ink px-2.5 text-[11px] font-semibold text-white shadow-[0_1px_3px_rgba(0,0,0,.18)]">Review</span>}
          </div>
        )}
        {movie.played && (
          <span className="absolute bottom-2 left-2 inline-flex h-6 items-center rounded-full bg-white/95 px-2.5 text-[11px] font-semibold text-ink shadow-[0_1px_3px_rgba(0,0,0,.18)]">Watched</span>
        )}
      </div>
      <div className="mt-2 flex items-baseline justify-between gap-2 px-0.5">
        <span className="truncate text-[13px] font-semibold tracking-[-0.01em] text-ink" title={movie.title}>
          {movie.title}
        </span>
        {movie.year ? <span className="shrink-0 text-[12.5px] tabular-nums text-faint">{movie.year}</span> : null}
      </div>
    </button>
  );
}
