import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, RouterProvider } from "react-router";
import "./index.css";

// Placeholder SPA shell — implemented in the "Web app" step.
const router = createBrowserRouter([{ path: "/", element: <p className="p-4">Sroka</p> }], {
  basename: "/app",
});
const queryClient = new QueryClient();

const el = document.getElementById("root");
if (el) {
  createRoot(el).render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </StrictMode>,
  );
}
