import React from "react";
import ReactDOM from "react-dom/client";

import "weui/dist/style/weui.min.css";

import App from "./App";
import "./styles.css";
import "./sidebar.css";
import "./detail.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
