import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { RouterProvider, createBrowserRouter } from "react-router";
import "./index.css";
import ErrorBoundary from "./components/ErrorBoundary.tsx";
import { installGlobalErrorHandlers } from "./lib/error-reporting.ts";
import Shell from "./components/Shell.tsx";
import { ToastProvider } from "./lib/store.tsx";
import Admin from "./routes/Admin.tsx";
import Library from "./routes/Library.tsx";
import Reader from "./routes/Reader.tsx";
import Settings from "./routes/Settings.tsx";
import Share from "./routes/Share.tsx";
import Tags from "./routes/Tags.tsx";

const router = createBrowserRouter(
  [
    {
      element: <Shell />,
      children: [
        { path: "/", element: <Library state="unread" /> },
        { path: "/archive", element: <Library state="archived" /> },
        { path: "/favorites", element: <Library state="favorites" /> },
        { path: "/all", element: <Library state="all" /> },
        { path: "/tag/:name", element: <Library state="all" /> },
        { path: "/tags", element: <Tags /> },
        { path: "/item/:id", element: <Reader /> },
        { path: "/settings", element: <Settings /> },
        { path: "/share", element: <Share /> },
        { path: "/admin", element: <Admin /> },
        { path: "*", element: <Library state="unread" /> },
      ],
    },
  ],
  { basename: "/app" },
);

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 15_000, refetchOnWindowFocus: false, retry: 1 } },
});

installGlobalErrorHandlers();

const el = document.getElementById("root");
if (el) {
  createRoot(el).render(
    <StrictMode>
      <ErrorBoundary>
      <QueryClientProvider client={queryClient}>
        <ToastProvider>
          <RouterProvider router={router} />
        </ToastProvider>
      </QueryClientProvider>
      </ErrorBoundary>
    </StrictMode>,
  );
}
