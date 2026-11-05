/** Firebase web config injected by vite.config.ts from apps/web/firebase.config.json; null when the file is absent. */
interface FirebaseWebConfig {
  apiKey: string;
  authDomain: string;
  projectId: string;
  appId: string;
  measurementId: string;
}
declare const __FIREBASE_CONFIG__: FirebaseWebConfig | null;
