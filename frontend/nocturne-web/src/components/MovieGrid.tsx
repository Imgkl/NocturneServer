import type { Movie } from '../lib/types';
import { MovieTile } from './MovieTile';
import { MovieListRow } from './MovieListRow';

export type ViewMode = 'tile' | 'list';

interface MovieGridProps {
  movies: Movie[];
  viewMode: ViewMode;
  onEditMovie: (movie: Movie) => void;
}

export function MovieGrid({ movies, viewMode, onEditMovie }: MovieGridProps) {
  if (viewMode === 'tile') {
    return (
      <div className="grid gap-5 md:gap-6 grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 2xl:grid-cols-6">
        {movies.map((m) => (
          <MovieTile key={m.jellyfinId} movie={m} onEdit={() => onEditMovie(m)} />
        ))}
      </div>
    );
  }
  return (
    <div className="border border-border bg-bg">
      {movies.map((m) => (
        <MovieListRow key={m.jellyfinId} movie={m} onEdit={() => onEditMovie(m)} />
      ))}
    </div>
  );
}
