import { useState } from 'react';
import { posterUrl } from '../lib/api';
import type { Movie } from '../lib/types';

interface MovieListRowProps {
  movie: Movie;
  onEdit: () => void;
}

export function MovieListRow({ movie, onEdit }: MovieListRowProps) {
  const [imgFailed, setImgFailed] = useState(false);
  const tags = movie.tags || [];
  return (
    <button
      onClick={onEdit}
      className="group w-full text-left flex items-center gap-4 px-4 lg:px-6 py-3 border-b border-border hover:bg-surface transition-colors cursor-pointer"
    >
      <div className="w-10 h-14 bg-surface border border-border flex-shrink-0 overflow-hidden">
        {!imgFailed && (
          <img
            src={posterUrl(movie.jellyfinId, 'thumb')}
            alt=""
            loading="lazy"
            onError={() => setImgFailed(true)}
            className="w-full h-full object-cover"
          />
        )}
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-[14px] text-text truncate">{movie.title}</span>
          {movie.year ? <span className="text-muted text-[13px] flex-shrink-0">({movie.year})</span> : null}
          {movie.needsReview && (
            <span className="text-[9px] uppercase tracking-widest text-muted border border-border px-1.5 py-0.5 flex-shrink-0">
              Review
            </span>
          )}
        </div>
        <div className="mt-1.5 flex flex-wrap gap-1.5 text-[10px] uppercase tracking-wider">
          {tags.length === 0 ? (
            <span className="text-muted italic normal-case tracking-normal text-[11px]">Untagged</span>
          ) : (
            tags.map((t) => (
              <span
                key={t.slug}
                className="text-text-dim border border-border px-2 py-0.5"
              >
                {t.title}
              </span>
            ))
          )}
        </div>
      </div>
      <PencilIcon className="flex-shrink-0 text-muted group-hover:text-text transition-colors" />
    </button>
  );
}

function PencilIcon({ className = '' }: { className?: string }) {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden
    >
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.121 2.121 0 1 1 3 3L7 19l-4 1 1-4 12.5-12.5z" />
    </svg>
  );
}
