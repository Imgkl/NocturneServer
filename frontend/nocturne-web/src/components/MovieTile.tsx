import { useState } from 'react';
import { posterUrl } from '../lib/api';
import type { Movie } from '../lib/types';

interface MovieTileProps {
  movie: Movie;
  onEdit: () => void;
}

export function MovieTile({ movie, onEdit }: MovieTileProps) {
  const [imgFailed, setImgFailed] = useState(false);
  const tags = movie.tags || [];
  const visibleTags = tags.slice(0, 3);
  const extra = tags.length - visibleTags.length;

  return (
    <button
      onClick={onEdit}
      className="group text-left cursor-pointer"
      aria-label={`Edit tags for ${movie.title}`}
    >
      <div className="w-full aspect-[2/3] bg-surface border border-border group-hover:border-border-hover transition-colors overflow-hidden relative">
        {imgFailed ? (
          <div className="w-full h-full flex items-center justify-center p-4 text-center">
            <span className="font-serif italic text-lg text-text leading-tight">{movie.title}</span>
          </div>
        ) : (
          <img
            src={posterUrl(movie.jellyfinId, 'medium')}
            alt=""
            loading="lazy"
            onError={() => setImgFailed(true)}
            className="w-full h-full object-cover"
          />
        )}
        {movie.needsReview && (
          <span className="absolute top-2 left-2 text-[9px] uppercase tracking-widest text-text bg-bg/90 px-2 py-0.5">
            Review
          </span>
        )}
      </div>
      <div className="mt-2 min-h-[44px]">
        <div className="text-[13px] text-text truncate" title={movie.title}>
          {movie.title}
          {movie.year ? <span className="text-muted ml-1.5">({movie.year})</span> : null}
        </div>
        <div className="mt-1 flex flex-wrap gap-x-2 gap-y-0 text-[10px] uppercase tracking-wider">
          {tags.length === 0 ? (
            <span className="text-muted">Untagged</span>
          ) : (
            <>
              {visibleTags.map((t) => (
                <span key={t.slug} className="text-text-dim">
                  {t.title}
                </span>
              ))}
              {extra > 0 && <span className="text-muted">+{extra}</span>}
            </>
          )}
        </div>
      </div>
    </button>
  );
}
