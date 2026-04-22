import type { HTMLAttributes } from 'react';

interface CardProps extends HTMLAttributes<HTMLDivElement> {
  padded?: boolean;
}

export function Card({ padded = true, className = '', ...props }: CardProps) {
  return (
    <div
      {...props}
      className={`bg-surface border border-border ${padded ? 'p-5' : ''} ${className}`}
    />
  );
}
