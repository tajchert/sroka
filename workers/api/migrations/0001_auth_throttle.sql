CREATE TABLE `auth_throttle` (
	`key` text PRIMARY KEY NOT NULL,
	`count` integer DEFAULT 0 NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `auth_throttle_expires` ON `auth_throttle` (`expires_at`);