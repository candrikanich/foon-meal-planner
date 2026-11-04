<script setup lang="ts">
import { beats, foundingOffer, mission, tagline } from "~/content";

const { public: config } = useRuntimeConfig();
const title = "Foon: family dinner, planned together";
const description = `${tagline} ${mission}`;

useSeoMeta({
  title,
  description,
  ogTitle: title,
  ogDescription: description,
  ogType: "website",
  ogUrl: config.siteUrl,
  ogImage: `${config.siteUrl}/og-icon.png`,
  twitterCard: "summary",
});
useHead({ link: [{ rel: "canonical", href: config.siteUrl }] });
</script>

<template>
  <section class="hero">
    <div class="wrap">
      <p class="eyebrow">Foon &middot; family dinner planner for iPhone</p>
      <h1>{{ tagline }}</h1>
      <p class="lead">{{ mission }}</p>
      <a class="button" href="#waitlist">Join the founding-family waitlist</a>
    </div>
  </section>

  <section class="section" aria-labelledby="how">
    <div class="wrap">
      <h2 id="how">How it works</h2>
      <ol class="beats">
        <li v-for="beat in beats" :key="beat.title">
          <h3>{{ beat.title }}</h3>
          <p>{{ beat.body }}</p>
        </li>
      </ol>
    </div>
  </section>

  <section class="section" aria-labelledby="see">
    <div class="wrap">
      <h2 id="see">A look inside</h2>
      <Screenshots />
    </div>
  </section>

  <section id="waitlist" class="section" aria-labelledby="founding">
    <div class="narrow">
      <div class="card offer">
        <p class="eyebrow">{{ foundingOffer.summary }}</p>
        <h2 id="founding">{{ foundingOffer.heading }}</h2>
        <ul>
          <li v-for="point in foundingOffer.points" :key="point">{{ point }}</li>
        </ul>
        <p class="fineprint">{{ foundingOffer.fineprint }}</p>
        <WaitlistForm />
      </div>
    </div>
  </section>
</template>
