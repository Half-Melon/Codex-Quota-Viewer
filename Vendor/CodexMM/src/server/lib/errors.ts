import type { ApiErrorCode, ApiErrorDetails } from "../../shared/contracts";

export class AppError extends Error {
  readonly statusCode: number;
  readonly code: ApiErrorCode;
  readonly details?: ApiErrorDetails;

  constructor(
    statusCode: number,
    code: ApiErrorCode,
    message: string,
    details?: ApiErrorDetails,
  ) {
    super(message);
    this.name = "AppError";
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
    Object.setPrototypeOf(this, new.target.prototype);
  }
}
