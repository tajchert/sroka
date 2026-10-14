CREATE TABLE `content_refs` (
	`content_id` text NOT NULL,
	`user_id` text NOT NULL,
	`at` integer NOT NULL,
	PRIMARY KEY(`content_id`, `user_id`)
);
--> statement-breakpoint
CREATE INDEX `content_refs_user` ON `content_refs` (`user_id`);--> statement-breakpoint
CREATE TABLE `gc_state` (
	`k` text PRIMARY KEY NOT NULL,
	`v` text NOT NULL
);
--> statement-breakpoint
ALTER TABLE `content` ADD `cacheable` integer DEFAULT 1 NOT NULL;--> statement-breakpoint
ALTER TABLE `content` ADD `last_used_at` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `content` ADD `gc_at` integer;--> statement-breakpoint
CREATE INDEX `content_last_used` ON `content` (`last_used_at`);--> statement-breakpoint
-- Hand-added: existing rows start their GC grace period at parse time.
UPDATE `content` SET `last_used_at` = `parsed_at`;