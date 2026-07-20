# Corvux UI Style Guide

Esta guía define cómo debe verse, sentirse y evolucionar la interfaz de Corvux. No es una colección de preferencias decorativas: es el contrato visual del producto.

Cada mejora de UI debe aumentar al menos una de estas cualidades sin degradar las demás:

1. Claridad: entender qué está pasando en pocos segundos.
2. Jerarquía: distinguir estado, acción principal y detalle secundario.
3. Confianza: representar datos reales sin inventar actividad ni resultados.
4. Eficiencia: reducir pasos, ruido y carga cognitiva.
5. Consistencia: reutilizar patrones antes de crear variantes.
6. Adaptabilidad: funcionar en escritorio, móvil, tema claro y oscuro.

## 1. Identidad del producto

Corvux es un observatorio operativo para agentes. La UI debe sentirse como una combinación de:

- Mission control: estados claros, telemetría y decisiones visibles.
- Instrumento profesional: precisión, densidad controlada y tipografía legible.
- Producto premium: profundidad sutil, movimiento breve y acabados consistentes.

La interfaz no debe parecer un dashboard genérico, una plantilla administrativa ni una colección de tarjetas independientes.

### Principio rector

> Primero la señal, después el contexto y finalmente el detalle.

En cada pantalla, el usuario debe poder responder rápidamente:

- ¿Dónde estoy?
- ¿Qué está ocurriendo ahora?
- ¿Hay algo que necesita mi atención?
- ¿Cuál es la acción principal?
- ¿Dónde puedo profundizar?

## 2. Lenguaje visual

### Color

La base es neutral. El color comunica significado y no se usa como decoración arbitraria.

| Token | Significado |
| --- | --- |
| `--brand` | Foco, selección, fase activa y acción distintiva de Corvux |
| `--ok` | En vivo, completado, gate aprobado y operación saludable |
| `--wait` | Espera, precaución, decisión pendiente o trabajo sin commit |
| `--bad` | Bloqueo, fallo, deploy rojo o acción destructiva |
| `--foreground` | Contenido principal y acciones neutrales |
| `--muted-foreground` | Contexto, metadatos y contenido secundario |

Reglas:

- No usar `--brand` para todos los elementos interactivos.
- No depender únicamente del color para comunicar estado; añadir texto o icono.
- Mantener contraste AA en texto y controles.
- Usar transparencias y `color-mix()` para derivar superficies; evitar nuevos hexadecimales aislados.
- Todo color nuevo debe funcionar también en `.dark`.

### Tipografía

- Encabezados: `var(--font-heading)` / Geist.
- Cuerpo: `var(--font-sans)` / Inter.
- IDs, métricas y datos técnicos: `ui-monospace`, SFMono o Menlo.
- Títulos grandes: compactos, con tracking negativo y líneas cortas.
- Labels: mayúsculas pequeñas y tracking amplio.
- Texto descriptivo: frases cortas, directas y sin jerga innecesaria.

Escala preferida:

- Display: `clamp(30px, 3–4vw, 48px)`.
- Título de tarjeta: `13–17px`.
- Cuerpo: `11.5–13px`.
- Caption: `8–10.5px`.

No introducir tamaños nuevos si uno existente resuelve la jerarquía.

### Superficies y profundidad

- Las tarjetas usan bordes hairline, un highlight interior y sombras suaves.
- El blur se reserva para elementos flotantes: popovers, sheets y command bar.
- Las superficies persistentes logran profundidad con alpha, gradiente y sombra; no con blur repetido.
- Los radios deben pertenecer al sistema existente: controles `10–12px`, tarjetas `16–20px`, héroes `24–30px`.
- Evitar cajas dentro de cajas cuando un divisor o cambio de fondo sea suficiente.

### Iconografía

- Usar Lucide para conservar peso y geometría consistentes.
- Tamaño normal: `12–16px`.
- Un icono debe aportar semántica; no duplicar texto sin propósito.
- Los iconos activos pueden vivir dentro de un tile sutil.
- No mezclar emojis con Lucide en controles principales.

### Movimiento

- Las transiciones deben durar entre `120ms` y `220ms`.
- Usar el easing `--ease` del sistema.
- El movimiento explica estado: hover, apertura, actividad en vivo o cambio de vista.
- Evitar animaciones continuas salvo señales realmente vivas.
- Respetar `prefers-reduced-motion`.

## 3. Arquitectura de una pantalla

Una vista completa debe seguir esta jerarquía cuando aplique:

1. Command bar: ubicación global y acciones persistentes.
2. Hero o view header: identidad de la vista, estado y propósito.
3. Señales prioritarias: bloqueos, esperas o información crítica.
4. Contenido operativo: datos, controles o recorrido principal.
5. Evidencia: historia, repos, desglose o metadatos.

No todas las vistas necesitan un hero grande. Debe usarse cuando la pantalla representa una misión, un flujo de creación o una primera experiencia importante.

### Encabezados

Un encabezado debe contener:

- Eyebrow corto para contexto.
- Título inequívoco.
- Descripción de una línea.
- Estado o acción relevante, si existe.

Evitar títulos técnicos enormes que consuman toda la pantalla. Los IDs largos deben usar tamaño responsive y `break-words`.

### Secciones

- Separar secciones por significado, no por necesidad de llenar la página.
- Usar título corto y una descripción funcional.
- Numerar secciones cuando formen un flujo.
- Mantener el contenido relacionado dentro de la misma superficie.

### Tarjetas

Una tarjeta debe representar una unidad real: tarea, sesión, repo, configuración o evento.

Cada tarjeta necesita una jerarquía interna:

1. Estado o categoría.
2. Identidad principal.
3. Contexto.
4. Métricas o acciones.

No crear tarjetas para una sola línea si un row o badge es suficiente.

## 4. Sidebar

El sidebar debe orientar, no competir con el contenido.

- La marca y el selector de máquina aparecen primero.
- La acción “Nueva tarea” es el CTA operativo principal.
- Los indicadores muestran únicamente datos accionables y reales.
- Los grupos usan nombres claros: Observar, Operar y Guía.
- La opción activa combina fondo, rail e icono; no depende solo del texto en negrita.
- Los badges deben comunicar volumen o estado, no decoración.
- El footer contiene conectividad y tema, con presencia discreta.
- En móvil se presenta como sheet y debe poder cerrarse al navegar.

No añadir más de una acción primaria al sidebar.

## 5. Formularios y creación de tareas

Los formularios complejos deben sentirse como una configuración guiada, no como una lista de inputs.

### Orden recomendado

1. Resultado esperado.
2. Contexto y criterios.
3. Origen o vinculación.
4. Configuración de ejecución.
5. Guardrails.
6. Resumen y lanzamiento.

### Campos

- Label siempre visible; el placeholder no sustituye al label.
- Añadir hints solo si ayudan a tomar una decisión.
- Mostrar unidades y límites cerca del campo.
- Dar altura suficiente a descripciones largas.
- Los defaults recomendados deben estar explícitos.
- No borrar información del usuario al cambiar opciones relacionadas.

### Acción final

- El botón principal debe describir el resultado: “Lanzar misión”, no “Enviar”.
- Mostrar por qué está deshabilitado.
- Durante la operación, reemplazar el label con un estado claro.
- Después del éxito, enseñar ID y destino de la ejecución.
- Los errores deben explicar qué no ocurrió y conservar los datos introducidos.

## 6. Estados y telemetría

La UI solo representa hechos derivados del snapshot o del bus.

- Verde pulsante significa actividad confirmada en vivo.
- “Reciente” no equivale a “en vivo”.
- Un bloqueo debe tener el mismo peso visual que un éxito.
- Las esperas humanas deben indicar qué decisión falta.
- Los números deben incluir unidad o label.
- Los estados vacíos deben orientar la siguiente acción.
- Nunca introducir datos ficticios para que una vista parezca completa.

## 7. Gráficas e historiales

Una visualización debe responder una pregunta concreta.

- Reducir espacio vacío antes de aumentar decoración.
- Mantener labels legibles y escalas honestas.
- El hover aporta detalle; la lectura básica debe funcionar sin hover.
- Evitar scroll horizontal en escritorio.
- En móvil, el scroll interno es aceptable si preserva la lectura y no ensancha la página.
- Las leyendas deben ser cortas y cercanas a la visualización.
- Los eventos repetidos deben mostrar contexto, por ejemplo `Fase · Review`.
- La historia se organiza por día y jerarquiza decisiones, supuestos, bloqueos y éxitos.

## 8. Responsive

Cada cambio debe validarse al menos en:

- Escritorio amplio: aproximadamente `1280px`.
- Tablet o viewport intermedio.
- Móvil: `390 × 844`.

Reglas:

- Las columnas pasan a una sola columna antes de comprimir el contenido.
- El CTA principal permanece visible y usable.
- No debe existir scroll horizontal de página.
- Los targets táctiles importantes miden al menos `40px` cuando el espacio lo permite.
- Los textos técnicos pueden truncarse, pero deben conservar acceso al valor completo cuando sea crítico.
- Los elementos sticky deben dejar de ser sticky si perjudican el flujo móvil.

## 9. Tema oscuro

El tema oscuro no es una inversión automática del claro.

- Reducir blancos puros y contrastes agresivos.
- Mantener separación entre fondo, card y popover.
- Revisar gradientes y transparencias individualmente.
- Las sombras oscuras deben aportar profundidad sin crear halos sucios.
- Los colores semánticos deben seguir siendo distinguibles.

## 10. Accesibilidad

- Controles nativos o componentes accesibles para botones, selects, checkboxes y diálogos.
- Todo control necesita nombre accesible.
- El foco debe ser visible.
- Las acciones deben funcionar con teclado.
- No colocar acciones en un `div` sin role, foco y manejo de teclado.
- Respetar jerarquía de headings.
- Los mensajes importantes no dependen solo de iconos o color.
- No usar texto con opacidad tan baja que deje de ser legible.

## 11. Cómo ejecutar cada mejora de UI

Toda mejora debe seguir este ciclo:

### 1. Auditar

- Abrir la vista con datos reales.
- Identificar la pregunta principal de la pantalla.
- Detectar problemas de jerarquía, densidad, overflow, consistencia y estados.
- Revisar componentes existentes antes de crear uno nuevo.

### 2. Definir el resultado

Antes de editar, establecer:

- Qué será más fácil de entender.
- Qué acción tendrá mayor claridad.
- Qué ruido se eliminará.
- Qué datos continuarán siendo reales.

### 3. Implementar

- Modificar exclusivamente archivos de UI cuando ese sea el alcance.
- Reutilizar tokens, primitivas y patrones existentes.
- Mantener intactos contratos de API y comportamiento operativo salvo autorización explícita.
- Construir primero la jerarquía; añadir polish al final.

### 4. Validar visualmente

- Usar datos reales, no fixtures inventados.
- Revisar escritorio y móvil.
- Revisar tema claro y oscuro.
- Probar estados activos, vacíos, loading, error y disabled cuando existan.
- Comprobar que popovers, sheets y dropdowns mantienen el orden correcto de capas.

### 5. Validar técnicamente

Ejecutar:

```bash
npm run build
npm run lint
```

Cuando la UI se embebe en `harness-daemon`:

```bash
scripts/sync-assets.sh ../harness-installer
go test ./...
```

La sincronización no autoriza cambios ajenos a la UI. Cualquier archivo generado fuera de `internal/webui/dist` debe revisarse y restaurarse si no pertenece al alcance.

### 6. Entregar

Explicar de forma concreta:

- Qué cambió visualmente.
- Qué problema resuelve.
- Qué archivos principales se modificaron.
- Qué viewports y temas se validaron.
- Qué pruebas pasaron.
- Cualquier warning preexistente que permanezca.

No describir una UI como “mejor” sin explicar qué se volvió más claro, rápido o confiable.

## 12. Checklist obligatorio

Antes de considerar terminada una mejora:

- [ ] La acción principal se identifica en menos de tres segundos.
- [ ] El estado actual se entiende sin depender únicamente del color.
- [ ] Los datos mostrados provienen de fuentes reales.
- [ ] No existe scroll horizontal de página en escritorio o móvil.
- [ ] La vista funciona a `390 × 844`.
- [ ] La vista funciona en tema claro y oscuro.
- [ ] El foco y navegación por teclado siguen funcionando.
- [ ] Los estados loading, vacío, error y disabled son comprensibles.
- [ ] No se añadieron colores, radios o sombras fuera del sistema sin justificación.
- [ ] No se duplicó un componente existente.
- [ ] `npm run build` pasa.
- [ ] `npm run lint` no introduce warnings nuevos.
- [ ] Los artefactos compilados están sincronizados cuando corresponde.
- [ ] No se modificó lógica de backend fuera del alcance autorizado.

## 13. Archivos de referencia

- Sistema visual y tokens: `src/index.css`.
- Shell y command bar: `src/App.tsx`.
- Navegación global: `src/components/app-sidebar.tsx`.
- Primitivas compartidas: `src/components/ui/`.
- Componentes reutilizables: `src/components/bits.tsx`.
- Flujo de creación: `src/views/new-task.tsx`.
- Detalle de misión: `src/views/task-detail.tsx`.

Cuando una nueva decisión visual deba repetirse en más de una vista, debe documentarse aquí y convertirse en token o componente compartido.
