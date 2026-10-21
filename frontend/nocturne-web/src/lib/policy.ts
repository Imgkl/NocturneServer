import type { ClassifierProvider, MoodBuckets, PolicyVersion } from './types';

// The words the UI uses for the grader and the policy versions, in one place.
export const GRADER_LABEL: Record<ClassifierProvider, string> = {
  none: "Off: AI's confidence decides",
  jev: 'Jev (TypeSafe)',
};

export const POLICY_LABEL: Record<PolicyVersion, string> = {
  p1: 'AI proposes, Jev grades',
  p0: 'Jev alone',
  'p-legacy': "AI's confidence only",
  pr: 'Dry run, nothing applied',
};

export const POLICY_HINT: Record<PolicyVersion, string> = {
  p1: "A mood is applied when AI names it and Jev agrees above the mood's floor. AI's moods below the floor go to review.",
  p0: "Jev's probabilities alone decide. AI's answer is kept for the record.",
  'p-legacy': "AI's own confidence against the floors, the way the tagger worked before the grader.",
  pr: 'AI runs and its answer is stored, but nothing is applied. For comparing policies on the Accuracy page.',
};

export const POLICY_ORDER: PolicyVersion[] = ['p1', 'p0', 'p-legacy', 'pr'];

export function policyLabel(version: string): string {
  return (POLICY_LABEL as Record<string, string>)[version] ?? version;
}

export function pct(x: number | null | undefined, digits = 0): string {
  return x == null ? '-' : `${(x * 100).toFixed(digits)}%`;
}

export function moodTitle(moods: MoodBuckets, slug: string): string {
  return moods[slug]?.title ?? slug;
}
