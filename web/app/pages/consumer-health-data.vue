<script setup lang="ts">
import { POSTAL_ADDRESS, SUPPORT_EMAIL } from "~/content";

useSeoMeta({
  title: "Consumer Health Data Policy: Foon",
  description: "How Foon keeps and uses the one kind of health information it has: food allergies.",
});
</script>

<template>
  <article class="narrow prose section">
    <h1>Consumer Health Data Policy</h1>
    <p class="draft">
      This is a plain-English summary. Our full consumer health data policy is being finalised and will be published
      here before Foon opens to everyone.
    </p>
    <p>
      The only health information Foon keeps is food allergies. This page covers them, separately from our
      <NuxtLink to="/privacy">privacy summary</NuxtLink>.
    </p>

    <h2>What we keep and why</h2>
    <ul>
      <li>For each person in a household: which of the 9 major US food allergens apply, and any other food allergies typed in.</li>
      <li>We use them only to flag dishes and shopping items that contain them.</li>
      <li>They're never sold, never used for ads, never sent anywhere for AI, and never put in a notification's text.</li>
      <li>A parent enters them in the app, or an adult enters their own. We don't get them from anywhere else.</li>
    </ul>

    <h2>Agreeing first</h2>
    <p>
      Foon keeps allergies only after a parent agrees in the app, and an adult who isn't a parent agrees before adding
      their own. We record who agreed, when, and which wording they saw.
    </p>

    <h2>Who receives them</h2>
    <p>
      Only your household, which sees everyone's allergies so the family knows why a dish is flagged, and our hosting
      provider, Supabase, which stores them for us. We don't share them with anyone else.
    </p>

    <h2>Changing your mind</h2>
    <ul>
      <li>A parent can change or remove anyone's allergies on their profile in Family, and an adult can change their own.</li>
      <li>Turning off Allergy alerts in Family withdraws the household's agreement and erases every allergy it has, right away.</li>
      <li>Deleting your account deletes your allergies; deleting the household deletes everyone's.</li>
      <li>
        To ask what we hold, or for anything you can't do in the app, write to
        <a :href="`mailto:${SUPPORT_EMAIL}`">{{ SUPPORT_EMAIL }}</a>.
      </li>
    </ul>

    <h2>Contact</h2>
    <address>
      The Recruiting Compass LLC<br>
      <template v-for="line in POSTAL_ADDRESS" :key="line">{{ line }}<br></template>
      <a :href="`mailto:${SUPPORT_EMAIL}`">{{ SUPPORT_EMAIL }}</a>
    </address>
  </article>
</template>
