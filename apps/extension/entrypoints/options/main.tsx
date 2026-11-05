import { createRoot } from "react-dom/client";
import "../../assets/tailwind.css";
import { installGlobalErrorHandlers } from "../../lib/error-reporting.ts";
import { Options } from "./Options.tsx";

installGlobalErrorHandlers();
const el = document.getElementById("root");
if (el) createRoot(el).render(<Options />);
