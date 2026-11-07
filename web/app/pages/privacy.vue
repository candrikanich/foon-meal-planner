<script setup lang="ts">
import { PRIVACY_UPDATED, SUPPORT_EMAIL } from "~/content";

useSeoMeta({ title: "Privacy: Foon", description: "What Foon keeps, and what this website keeps when you join the waitlist." });
</script>

<template>
  <article class="narrow prose section">
    <h1>Privacy</h1>
    <p class="fineprint">Last updated {{ PRIVACY_UPDATED }}</p>
    <p class="draft">
      This is a plain-English summary. Our full privacy policy is being finalised and will be published here before Foon
      opens to everyone.
    </p>

    <h2>This website and the waitlist</h2>
    <ul>
      <li>This website has no ads, no tracking scripts, and sets no cookies.</li>
      <li>
        If you join the waitlist, we keep your email address and, if you give it, your first name. The waitlist is for
        adults.
      </li>
      <li>We use them to email you a link to confirm your spot, and to tell you about Foon's founding-family offer and when Foon opens.</li>
      <li>
        Until you confirm, your signup is pending, and we delete a pending signup 30 days after the last email we sent
        for it. After you confirm, we keep your email, and your name if you gave one, until you unsubscribe. Every email
        has an unsubscribe link, and unsubscribing deletes your email address and name right away.
      </li>
      <li>
        To limit abuse, the form keeps a scrambled (hashed) version of your network address for up to 2 days. It can't be
        turned back into the address.
      </li>
      <li>We send these emails through a mail service, Resend, and store the list with our database host, Supabase. We don't sell or share the list.</li>
    </ul>

    <h2>What the Foon app keeps</h2>
    <ul>
      <li>Your household's name and emoji, first names, avatars, and who is a kid, a parent, or a planner.</li>
      <li>Allergies a parent adds, and each person's usual schedule.</li>
      <li>Your meals and meal photos, plans, lists, ideas, votes on dinner, ratings, comments, serving notes, and who cooked.</li>
      <li>Your household's time zone, so Foon knows when last night's dinner was.</li>
      <li>
        Your Apple sign-in: an account ID, an email (which can be Apple's private relay address), and your first name if
        Apple shares it.
      </li>
      <li>Which reminders each person's device sent and whether they answered: the kind, the night, and the time, never the words.</li>
      <li>
        If your household subscribes, Apple's subscription status for it. Apple holds your payment details; Foon never
        sees them.
      </li>
      <li>Foon doesn't ask for birthdays, phone numbers, or your location.</li>
    </ul>

    <h2>What stays on your device</h2>
    <ul>
      <li>If a planner turns on busy-evening suggestions, Foon reads the times of calendar events on that device. It never saves or sends them.</li>
      <li>Receipt photos are read on the device and never kept or uploaded.</li>
      <li>Dinner-memory photos from your library are shown on the device. Foon never saves or uploads them.</li>
    </ul>

    <h2>Allergies and AI</h2>
    <p>
      Foon uses Apple's on-device model for its optional AI helpers. Allergies are never sent anywhere for AI, and the
      app has no ads and no tracking.
    </p>

    <h2>Who sees what</h2>
    <p>
      Everyone in your household sees the family, allergies, schedules, the plan, lists, ideas, votes, ratings, and who
      cooked. Other households can't see any of it.
    </p>

    <h2>Changing your mind</h2>
    <ul>
      <li>Parents can change or remove someone's allergies on their profile, and an adult can add and remove their own.</li>
      <li>Parents can delete everything about a kid on the kid's profile, sign-in account included, right away.</li>
      <li>Deleting a household in the app removes it from Foon for everyone, right away.</li>
      <li>Plan activity, votes on dinner, and the reminder log are deleted after eight weeks.</li>
      <li>
        To leave the waitlist, use the link in any waitlist email, or write to
        <a :href="`mailto:${SUPPORT_EMAIL}`">{{ SUPPORT_EMAIL }}</a>.
      </li>
    </ul>
    <p>
      How long a hosted backup keeps deleted data is part of the full policy we are finalising. Questions:
      <a :href="`mailto:${SUPPORT_EMAIL}`">{{ SUPPORT_EMAIL }}</a>.
    </p>
  </article>
</template>
