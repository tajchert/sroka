CREATE TABLE `parse_attempts` (
	`id` text PRIMARY KEY NOT NULL,
	`created_at` integer NOT NULL,
	`user_hash` text NOT NULL,
	`item_id` text NOT NULL,
	`domain` text NOT NULL,
	`url` text,
	`status` text NOT NULL,
	`error_code` text,
	`error_detail` text,
	`method` text NOT NULL,
	`fallback_outcome` text NOT NULL,
	`http_status` integer,
	`text_chars` integer,
	`word_count` integer,
	`images` integer,
	`duration_ms` integer,
	`render_ms` integer,
	`attempt` integer NOT NULL,
	`parser_version` integer NOT NULL,
	`rule_applied` integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE INDEX `parse_attempts_created` ON `parse_attempts` (`created_at`);--> statement-breakpoint
CREATE INDEX `parse_attempts_domain` ON `parse_attempts` (`domain`,`created_at`);--> statement-breakpoint
CREATE INDEX `parse_attempts_status` ON `parse_attempts` (`status`,`created_at`);--> statement-breakpoint
CREATE TABLE `render_budget` (
	`key` text PRIMARY KEY NOT NULL,
	`count` integer DEFAULT 0 NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `render_budget_expires` ON `render_budget` (`expires_at`);