/** Build-time Firebase web config (null = no analytics in this build). Separate module so tests can mock it. */
export const firebaseConfig: FirebaseWebConfig | null = __FIREBASE_CONFIG__;
export const hasAnalyticsConfig = (): boolean => firebaseConfig !== null;
