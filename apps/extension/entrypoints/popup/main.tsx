import { createRoot } from "react-dom/client";
import "../../assets/tailwind.css";

const el = document.getElementById("root");
if (el) createRoot(el).render(<p className="p-3">Sroka popup</p>);
