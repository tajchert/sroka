import { createRoot } from "react-dom/client";
import "../../assets/tailwind.css";
import { Options } from "./Options.tsx";

const el = document.getElementById("root");
if (el) createRoot(el).render(<Options />);
