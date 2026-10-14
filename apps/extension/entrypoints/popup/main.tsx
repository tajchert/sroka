import { createRoot } from "react-dom/client";
import "../../assets/tailwind.css";
import { App } from "./App.tsx";

document.body.classList.add("popup");
const el = document.getElementById("root");
if (el) createRoot(el).render(<App />);
