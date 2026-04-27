package main

import (
	"fmt"
	"runtime"
	"strings"

	"github.com/gofiber/fiber/v2"
)

type Body struct {
	UserID int64  `json:"user_id"`
	Active bool   `json:"active"`
	Name   string `json:"name"`
}

func main() {
	runtime.GOMAXPROCS(4)

	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
		ServerHeader:          "",
		ReadBufferSize:        16384,
		WriteBufferSize:       16384,
	})

	app.Get("/", func(c *fiber.Ctx) error {
		c.Set("Content-Type", "application/json")
		return c.SendString(`{"ok":true}`)
	})

	app.Get("/auth", func(c *fiber.Ctx) error {
		bearer := c.Get("Authorization")
		cookie := c.Get("Cookie")
		c.Set("Content-Type", "application/json")
		if bearer == "" || !strings.Contains(cookie, "session=") {
			return c.SendString(`{"authorized":false}`)
		}
		return c.SendString(`{"authorized":true}`)
	})

	app.Post("/users", func(c *fiber.Ctx) error {
		var b Body
		if err := c.BodyParser(&b); err != nil {
			c.Status(422)
			return c.SendString(`{"detail":"ValidationFailed"}`)
		}
		c.Set("Content-Type", "application/json")
		return c.SendString(fmt.Sprintf(`{"user_id":%d,"active":%t,"name":%q}`, b.UserID, b.Active, b.Name))
	})

	if err := app.Listen("127.0.0.1:8080"); err != nil {
		panic(err)
	}
}
