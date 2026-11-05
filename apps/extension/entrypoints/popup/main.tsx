import { createRoot } from "react-dom/client";
import "../../assets/popup.css";
import { installGlobalErrorHandlers } from "../../lib/error-reporting.ts";
import { App } from "./App.tsx";

installGlobalErrorHandlers();
const el = document.getElementById("root");
if (el) createRoot(el).render(<App />);
