import { createRoot } from "react-dom/client";
import "../../assets/popup.css";
import { App } from "./App.tsx";

const el = document.getElementById("root");
if (el) createRoot(el).render(<App />);
