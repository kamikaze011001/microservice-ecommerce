import { createApp } from 'vue';
import { createPinia } from 'pinia';
import App from './App.vue';
import { router } from './router';
import { installVueQuery } from './plugins/vue-query';
import './styles/main.css';

const app = createApp(App);
app.use(createPinia());
app.use(router);
installVueQuery(app);
app.mount('#app');
