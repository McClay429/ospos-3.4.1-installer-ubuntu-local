# Bugs encontrados en el paquete de distribución OSPOS 3.4.1 y sus soluciones

Este documento detalla, en orden cronológico de aparición durante una
instalación limpia desde cero, cada problema encontrado en
`opensourcepos.3.4.1.5f395d.zip` (el paquete "prebuilt" oficial) sobre un
stack LAMP tradicional (Ubuntu 22.04 + Apache 2.4 + PHP 8.1 + MariaDB, sin
Docker).

Entorno de referencia en el que se reprodujo todo:
- Ubuntu 22.04.5 LTS
- Apache 2.4
- PHP 8.1.2
- MariaDB
- OSPOS 3.4.1 (`opensourcepos.3.4.1.5f395d.zip`, sha256: `97437a43d2f5d6638906a3bb4efd3f51e49c7e98742ecf3b7d48689301d05080`)

---

## Bug #1 — Falta `app/Config/Locale.php`

**Síntoma:**

```
Error
Class "Config\Locale" not found
at APPPATH/Config/Services.php:51
```

Este error aparece al correr cualquier comando de `spark` (ej.
`php spark migrate`). En peticiones web normales puede no aparecer de
inmediato porque el código que lo dispara no siempre se ejecuta en el
primer request.

**Causa raíz:**

En `app/Config/Services.php`, dentro del método `language()`:

```php
namespace Config;
// ...
$requestLocale = Locale::getDefault();
```

Como el archivo vive en `namespace Config;`, PHP resuelve `Locale::` como
`Config\Locale` (namespace relativo), no como la clase nativa `\Locale` de
la extensión `intl` de PHP. Es un descuido de los autores: faltó anteponer
la barra invertida (`\Locale::getDefault()`) o agregar
`use Locale;` al inicio del archivo.

**Solución:**

Crear el archivo faltante como una clase puente que herede de la clase
nativa:

```php
<?php

namespace Config;

class Locale extends \Locale
{
}
```

Guardarlo en `app/Config/Locale.php`. Como `Config\Locale` hereda de
`\Locale`, cualquier llamada a métodos estáticos (`getDefault()`, etc.)
funciona igual.

> ⚠️ **Este fix requiere que la extensión PHP `intl` esté instalada**, ya
> que `\Locale` (la clase nativa de PHP a la que la nuestra hereda) viene
> de esa extensión. En una instalación mínima de PHP 8.1 sobre Ubuntu,
> `php-intl` **no se instala por defecto** — hay que agregarla:
>
> ```bash
> sudo apt install php-intl -y
> sudo phpenmod intl
> sudo systemctl restart apache2
> ```
>
> Si falta, el error cambia de "Class Config\Locale not found" a
> "Class Locale not found" (sin el namespace `Config\`) — apunta al mismo
> archivo `Services.php`, pero esta vez porque la clase nativa padre
> tampoco existe. Descubierto al probar el instalador en una VM limpia
> donde `php-intl` no venía preinstalada (a diferencia del servidor
> original, donde ya estaba presente de antes por otra razón).

---

## Bug #2 — Falta el archivo `spark`

**Síntoma:**

```bash
$ php spark migrate
Could not open input file: spark
```

**Causa raíz:**

El paquete de distribución de producción excluye deliberadamente (o por
error de empaquetado) el punto de entrada de la CLI de CodeIgniter 4. La
carpeta `vendor/codeigniter4/framework/system/Commands/` sí está completa
— solo falta el script que la invoca desde la raíz del proyecto.

**Solución:**

Descargar el archivo `spark` directamente del código fuente oficial del
mismo tag:

```bash
curl -sL -o spark \
  https://raw.githubusercontent.com/opensourcepos/opensourcepos/3.4.1/spark
chmod +x spark
```

---

## Bug #3 — `Database.php` ignora el `.env` y solo lee variables `MYSQL_*`

**Síntoma:**

```
CodeIgniter\Database\Exceptions\DatabaseException
Unable to connect to the database.
Main connection [MySQLi]: Access denied for user '****'@'localhost'
```

...incluso después de confirmar (con una conexión `mysqli` manual y con un
script de prueba que llama a `CodeIgniter\Config\DotEnv` directamente) que
las credenciales del `.env` son correctas y que el archivo sí se está
leyendo.

**Causa raíz:**

`app/Config/Database.php` en esta versión no usa el mecanismo estándar de
CodeIgniter 4 de sobreescribir sus propiedades públicas vía claves del
`.env` (`database.default.username`, etc.). En su lugar, tiene un
`__construct()` personalizado, pensado para el flujo de Docker de este
proyecto:

```php
public function __construct()
{
    parent::__construct();
    // ...
    foreach ([&$this->development, &$this->tests, &$this->default] as &$config) {
        $config['hostname'] = !getenv('MYSQL_HOST_NAME') ? $config['hostname'] : getenv('MYSQL_HOST_NAME');
        $config['username'] = !getenv('MYSQL_USERNAME') ? $config['username'] : getenv('MYSQL_USERNAME');
        $config['password'] = !getenv('MYSQL_PASSWORD') ? $config['password'] : getenv('MYSQL_PASSWORD');
        $config['database'] = !getenv('MYSQL_DB_NAME') ? $config['database'] : getenv('MYSQL_DB_NAME');
    }
}
```

Si esas cuatro variables de entorno del sistema operativo no existen, usa
los valores de ejemplo hardcodeados (`admin` / `pointofsale`) — sin
importar lo que digas en `database.default.*` dentro del `.env`. Esto no
está documentado en la guía de instalación estándar para servidores no-Docker.

**Solución:**

Definir esas cuatro variables de entorno a nivel de Apache (para peticiones
web) y exportarlas explícitamente al invocar `spark` por CLI (para
migraciones):

En el VirtualHost de Apache:

```apache
<VirtualHost *:80>
    # ...
    SetEnv MYSQL_HOST_NAME localhost
    SetEnv MYSQL_USERNAME ospos
    SetEnv MYSQL_PASSWORD tu_contraseña
    SetEnv MYSQL_DB_NAME ospos
</VirtualHost>
```

(Requiere `sudo a2enmod env`.)

Por línea de comandos:

```bash
sudo -u www-data \
  MYSQL_HOST_NAME=localhost \
  MYSQL_USERNAME=ospos \
  MYSQL_PASSWORD=tu_contraseña \
  MYSQL_DB_NAME=ospos \
  php spark migrate
```

---

## Bug #3B — Falta la extensión PHP `mysqli`

**Síntoma:**

```
CodeIgniter v4.6.0 Command Line Tool

[Error]
Undefined constant "CodeIgniter\Database\MySQLi\MYSQLI_STORE_RESULT"
at SYSTEMPATH/Database/Database.php:143
```

Aparece al correr `php spark migrate`, incluso con las credenciales y las
variables `MYSQL_*` del Bug #3 ya bien configuradas.

**Causa raíz:**

La constante `MYSQLI_STORE_RESULT` es parte de la extensión `mysqli` de
PHP. Si esa extensión no está instalada/habilitada, CodeIgniter 4 falla al
intentar definir su propia clase de conexión, incluso antes de intentar
conectarse a la base de datos. Una instalación mínima de
`apache2 + php8.1 + libapache2-mod-php8.1 + mariadb-server` en Ubuntu **no
instala `mysqli` automáticamente** — se necesita el paquete `php-mysql`
por separado.

Nota: el cliente de línea de comandos `mysql` (usado para importar
`database.sql` con `mysql -u ... < archivo.sql`) es un programa aparte que
no depende de esta extensión de PHP, por lo que ese paso puede funcionar
bien aunque falte `mysqli` — el error solo aparece cuando PHP mismo intenta
conectarse (via `spark migrate` o al cargar la aplicación web).

**Solución:**

```bash
sudo apt install php-mysql -y
sudo systemctl restart apache2
```

Verificar:
```bash
php -m | grep -i mysqli
```

---

## Bug #4 — Falta la extensión PHP `bcmath`

**Síntoma:**

```
Error
Call to undefined function App\Events\bcscale()
at APPPATH/Events/Load_config.php:54
```

Aparece justo después de un login exitoso, al cargar la configuración
global de la app (cálculo de decimales para totales/impuestos).

**Causa raíz:**

`bcscale()` es parte de la extensión `bcmath` de PHP, usada para operaciones
matemáticas de precisión arbitraria en montos monetarios. No viene incluida
por defecto en una instalación mínima de `php8.1` en Ubuntu, y no aparece
listada como dependencia explícita en la documentación de instalación.

**Solución:**

```bash
sudo apt install php-bcmath -y
sudo phpenmod bcmath
sudo systemctl restart apache2
```

---

## Bug #4B — Faltan más extensiones PHP requeridas (`gd`, `mbstring`, `curl`, `xml`)

**Síntoma:**

Al intentar iniciar sesión, la página recarga el formulario de login con el
mensaje:

```
The installation is not correct, check your php.ini file.
```

sin ningún detalle técnico adicional en pantalla (incluso en modo
`development`, porque no es una excepción de PHP sino una validación
propia de la aplicación).

**Causa raíz:**

OSPOS valida activamente, en cada intento de login
(`app/Config/Validation/OSPOSRules.php::installation_check()`), que estén
cargadas las siguientes 8 extensiones de PHP:

```php
$required_extensions = ['bcmath', 'intl', 'gd', 'openssl', 'mbstring', 'curl', 'xml', 'json'];
```

Si falta cualquiera de ellas, el login se rechaza con este mensaje
genérico, sin decir cuál falta (el detalle sí se escribe al log de la
aplicación vía `log_message('error', ...)`, en
`writable/logs/log-YYYY-MM-DD.log`, pero no se muestra en pantalla).

Una instalación mínima de `apache2 + php8.1 + libapache2-mod-php8.1 +
mariadb-server` en Ubuntu típicamente ya trae `openssl` y `json` (son parte
del "core" de PHP 8.1), pero **no trae por defecto** `gd`, `mbstring`,
`curl` ni `xml` como paquetes separados.

**Solución:**

```bash
sudo apt install php-gd php-mbstring php-curl php-xml -y
sudo systemctl restart apache2
```

Para diagnosticar cuáles faltan en un caso específico:

```bash
php -m | grep -Ei "bcmath|intl|gd|openssl|mbstring|curl|xml|json"
```

Compara la salida contra la lista completa de 8 requeridas — cualquiera
que no aparezca hay que instalarla. También puedes revisar el log de la
aplicación para más detalle:

```bash
sudo tail -n 20 /var/www/ospos/writable/logs/log-$(date +%Y-%m-%d).log
```

---

## Bug #5 — `database.sql` desactualizado (falta correr las migraciones reales)

**Síntoma:** múltiples, apareciendo uno tras otro conforme se navega la
aplicación:

```
Table 'ospos.ospos_sessions' doesn't exist
Table 'ospos.ospos_items' doesn't exist          (al intentar `spark migrate` a ciegas)
Table 'ospos.ospos_dinner_tables' doesn't exist  (al entrar a Config)
Unknown column 'menu_group' in 'WHERE'           (al entrar a /home)
You do not have permission to access the module named Errors.unknown
```

**Causa raíz:**

`app/Database/database.sql` (el esquema que la wiki oficial dice que puedes
importar para partir de cero) corresponde a una versión **anterior a la
migración 3.2.0** — le faltan tablas agregadas después (`dinner_tables`,
`expenses`, `tax_categories`, `cash_up`, etc.) y columnas como `menu_group`
en `ospos_grants`, que el código de la versión 3.4.1 ya da por hecho que
existen.

Las migraciones normales de CodeIgniter 4 (`app/Database/Migrations/*.php`)
sí completan el esquema correctamente **si se dejan correr desde una base
de datos recién creada con `database.sql`**, pero:

- No se pueden correr sin resolver primero los Bugs #1 y #2 (`spark` y
  `Config\Locale`).
- **No intentes "saltarte" las migraciones marcándolas como aplicadas a
  mano en la tabla `ospos_migrations` sin ejecutarlas de verdad** — esto
  fue un callejón sin salida que solo generó más tablas/columnas faltantes
  una por una. La única solución robusta es dejarlas correr de principio a
  fin.

**Solución:**

```bash
# 1. Importar el esquema base
mysql -u ospos -p ospos < app/Database/database.sql

# 2. Correr las migraciones reales (una vez resueltos los Bugs #1-#4)
sudo -u www-data \
  MYSQL_HOST_NAME=localhost \
  MYSQL_USERNAME=ospos \
  MYSQL_PASSWORD=tu_contraseña \
  MYSQL_DB_NAME=ospos \
  php spark migrate
```

Si el proceso se detiene a la mitad con un error de columna o entrada
duplicada, es porque una ejecución previa (manual o fallida a medias) ya
había aplicado parte de un script. Los `ALTER TABLE ADD COLUMN` de MySQL
se confirman de inmediato aunque el resto del script falle después — por
lo que hay que revisar manualmente qué parte de ese script específico ya
se aplicó, revertir solo esa parte (o eliminar los datos duplicados que
insertó), y volver a correr `spark migrate` para que continúe desde ese
mismo archivo. Los `INSERT`/`DELETE` sí se revierten solos si el script
falla, así que normalmente basta con:

```sql
-- Ejemplo: si falló por una columna que ya existe
ALTER TABLE ospos_grants DROP COLUMN menu_group;
```

...y volver a correr `spark migrate`.

Con `database.sql` importado y las 40 migraciones corriendo sin
intervención manual, el esquema queda idéntico al de una instalación de
fábrica — no hacen falta parches de datos a mano.

---

## Resumen de correcciones para reportar al proyecto oficial

Si vas a abrir un Issue en el repositorio de OSPOS, estos son los puntos
más claros y accionables:

1. `app/Config/Locale.php` falta en el repo (o falta el `\` en
   `Services.php` línea ~51).
2. El paquete de distribución (`opensourcepos.X.Y.Z.hash.zip`) no incluye
   `spark`.
3. `php-bcmath` y `php-intl` no están listados como dependencias
   requeridas en `INSTALL.md`/`BUILD.md`.
4. La guía de instalación para LAMP tradicional (wiki de Ubuntu) no
   menciona que `Database.php` requiere las variables de entorno
   `MYSQL_*` en vez de las claves `database.default.*` del `.env`.
5. `app/Database/database.sql` está desactualizado respecto al estado
   final que dejan las migraciones — sería útil regenerarlo o aclarar en
   la documentación que es obligatorio correr `spark migrate` después de
   importarlo.
